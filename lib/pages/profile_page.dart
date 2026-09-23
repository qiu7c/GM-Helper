import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/course.dart';
import '../services/app_info.dart';
import '../services/auth_store.dart';
import '../services/auto_login.dart';
import '../services/profile_service.dart';
import '../services/schedule_prefs.dart';
import '../services/schedule_service.dart';
import '../services/update_service.dart';
import '../widgets/glass.dart';
import 'about_page.dart';

/// "我的"页：检查登录状态，展示详细学籍信息，选择学期/校区，退出登录。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

enum _Status { checking, loggedIn, loggedOut }

class _ProfilePageState extends State<ProfilePage> {
  _Status _status = _Status.checking;
  Profile? _profile;

  List<SelectOption> _terms = [];
  List<SelectOption> _campuses = [];
  String? _term;
  String? _campus;

  /// 查到的可用新版本。null 表示"已是最新 / 还没查 / 查失败"，三种都不打扰用户。
  UpdateInfo? _update;
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    // 在别的页面登录/退出后，切回本页时自动重新检查
    AuthStore.authRevision.addListener(_onAuthChanged);
    _check();
    _checkUpdate();
  }

  @override
  void dispose() {
    AuthStore.authRevision.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) _check();
  }

  /// 检查轮次：登录成功会同时从好几条路触发 _check（监听 + 登录页回调），
  /// 只认最新那次的结果，避免旧响应把新数据盖回去。
  int _checkSeq = 0;

  Future<void> _check() async {
    final seq = ++_checkSeq;
    setState(() => _status = _Status.checking);

    final cookie = await AuthStore.getCookie();
    if (seq != _checkSeq) return;
    if (cookie == null || cookie.isEmpty) {
      setState(() => _status = _Status.loggedOut);
      return;
    }

    try {
      // 并行取学籍信息与课表下拉项(学期/校区)
      final profileF = ProfileService(cookie).fetch();
      final scheduleF = ScheduleService(cookie).fetch(
        term: await AuthStore.getLastTerm(),
        campus: await AuthStore.getLastCampus(),
      );
      final profile = await profileF;
      final schedule = await scheduleF;
      if (!mounted || seq != _checkSeq) return;
      setState(() {
        _status = _Status.loggedIn;
        _profile = profile;
        _terms = schedule.terms;
        _campuses = schedule.campuses;
        _term = schedule.selectedTerm;
        _campus = schedule.selectedCampus;
      });
      SchedulePrefs.instance.sync(term: _term, campus: _campus);
    } catch (e) {
      if (!mounted || seq != _checkSeq) return;
      if (e == ProfileService.sessionExpired ||
          e == ScheduleService.sessionExpired) {
        // 让出这一轮再清 cookie，免得上面那句 _check 重入时又被自己挡掉
        _checkSeq++;
        // 会话过期不是用户主动退出：课表缓存留着（见 AuthStore.clearSession），
        // 否则重登之前打开课表页会是一片空白。
        //
        // 带上这张失败的票：本页和课表页在同一个 IndexedStack 里，启动时
        // 同时发请求、同时判出失效。要是课表页那边已经先一步自动重登、换上
        // 新票，这里再去清就会把**刚存进来的新票删掉**，等于把用户从已经登好
        // 的状态里踢出去，只能手动登录。
        final cleared = await AuthStore.clearSession(failedCookie: cookie);
        if (!mounted) return;
        if (!cleared) {
          // 票换新了，这次失效作废：拿新票重查一次
          _check();
          return;
        }
        setState(() => _status = _Status.loggedOut);
      } else {
        setState(() => _status = _Status.loggedIn);
      }
    }
  }

  Future<void> _login() async {
    final ok = await AutoLogin.ensureLoggedIn(context);
    if (ok) _check();
  }

  Future<void> _logout() async {
    final autoOn = await AutoLogin.isConfigured();
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('退出登录'),
        content: Text('确定要退出登录吗？退出后需重新登录才能查看课表。'
            '${autoOn ? '\n\n已开启「自动登录」，本次使用期间不会自动登回去，但下次打开 App 仍会自动登录。' : ''}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('退出')),
        ],
      ),
    );
    if (confirm == true) {
      await AuthStore.clear();
      // 刚点完退出就被自动登回去太别扭：本次启动内不再自动登录
      AutoLogin.suppress();
      if (!mounted) return;
      setState(() {
        _status = _Status.loggedOut;
        _profile = null;
        _terms = [];
        _campuses = [];
      });
    }
  }

  Future<void> _pickTerm() async {
    if (_terms.isEmpty) return;
    final v = await _pickOption('选择学期', _terms, _term);
    if (v != null) {
      setState(() => _term = v);
      await SchedulePrefs.instance.setTerm(v); // 通知课表页重载
    }
  }

  Future<void> _pickCampus() async {
    if (_campuses.isEmpty) return;
    final v = await _pickOption('选择校区', _campuses, _campus);
    if (v != null) {
      setState(() => _campus = v);
      await SchedulePrefs.instance.setCampus(v);
    }
  }

  Future<String?> _pickOption(
      String title, List<SelectOption> opts, String? current) {
    final theme = Theme.of(context);
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          ...opts.map((o) => ListTile(
                title: Text(o.label),
                trailing: o.value == current
                    ? Icon(Icons.check, color: theme.colorScheme.primary)
                    : null,
                selected: o.value == current,
                onTap: () => Navigator.pop(context, o.value),
              )),
        ],
      ),
    );
  }

  String _labelOf(List<SelectOption> opts, String? value, String fallback) {
    if (value == null) return fallback;
    for (final o in opts) {
      if (o.value == value) return o.label;
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 内容从玻璃顶栏**底下**穿过去，玻璃背后才有东西可模糊
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(context: context, title: const Text('我的')),
      body: Builder(
        builder: (ctx) {
          // ⚠ 必须在 Scaffold **之下**读：`build()` 的 context 在它上面，
          // 拿到的是状态栏高度而不是顶栏高度
          final media = MediaQuery.of(ctx);
          return RefreshIndicator(
            onRefresh: _check,
            // 不偏这一下的话，下拉的转圈会出现在玻璃顶栏底下被挡住
            edgeOffset: media.padding.top,
            child: SingleChildScrollView(
              // 内容比屏幕短时也要能下拉刷新
              physics: const AlwaysScrollableScrollPhysics(),
              // 这里显式传内边距。原来是 ListView 且不给 padding，它会自己吃掉
              // MediaQuery 的那份（顶栏高度 + 悬浮底栏高度）——换成
              // SingleChildScrollView 就不自动吃了，得自己接上，否则内容会顶到
              // 状态栏和底栏底下
              padding: media.padding,
              // 用 Column 而不是 ListView：列表本身就一屏上下，不需要懒加载，而
              // 懒加载的副作用是滚出屏幕的行会被销毁、滚回来重新入场 —— 那样每
              // 上下滚一次就重播一遍淡入。Column 的 element 一直在，入场只播一次。
              child: Column(
                // 不 stretch 的话 Column 默认 center，ListTile 会被缩成内容宽
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _entered([
                  const SizedBox(height: 24),
                  _header(),
                  const SizedBox(height: 24),
                  if (_status == _Status.loggedIn) ..._loggedInTiles(),
                  if (_status == _Status.loggedOut) _loginTile(),
                  const Divider(),
                  _updateTile(),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('关于'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AboutPage()),
                    ),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------- 入场 ----------
  //
  // 每行往上挪 8px + 淡入，按序号依次错开。总时长压在 460ms：前 6 行逐步跟上来，
  // 再往后的行不再往后推 —— 学籍信息可能有十几条，一路 35ms 错下去最后一行要等
  // 大半秒才出现，那就不是"入场"是"加载慢"了。

  static const Duration _enterTotal = Duration(milliseconds: 460);
  static const Duration _enterFade = Duration(milliseconds: 240);
  static const Duration _enterStep = Duration(milliseconds: 35);
  static const int _enterMaxStep = 6;

  /// 给列表每一项套上入场动画。纯占位的间距和分割线不算进度，跳过它们。
  List<Widget> _entered(List<Widget> children) {
    final out = <Widget>[];
    var i = 0;
    for (final c in children) {
      if (c is SizedBox || c is Divider) {
        out.add(c);
      } else {
        out.add(_enter(i++, c));
      }
    }
    return out;
  }

  Widget _enter(int i, Widget child) {
    final total = _enterTotal.inMilliseconds.toDouble();
    final step = _enterStep.inMilliseconds *
        (i < _enterMaxStep ? i : _enterMaxStep);
    final start = step / total;
    final end = (step + _enterFade.inMilliseconds) / total;

    // 用一个共同时长 + 各自的 Interval 来错开，而不是给每行不同的 duration ——
    // 那只会让后面的行播得慢，不是"依次开始"。
    //
    // TweenAnimationBuilder 只在 end 变了的时候才重播，所以 _check() 刷新列表
    // 不会让整页重新入场；新插进来的行因为是新的 element，会正常入场。
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: _enterTotal,
      curve: Interval(start, end, curve: Curves.easeOut),
      builder: (_, t, inner) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - t)),
          child: inner,
        ),
      ),
      child: child,
    );
  }

  /// 「检查更新」一条。
  ///
  /// 启动时已经静默查过一次：查到新版就在这条上挂个红点提示，查不到就只显示
  /// 当前版本号。用户主动点时才有弹窗反馈。
  Widget _updateTile() {
    final scheme = Theme.of(context).colorScheme;
    final up = _update;
    return ListTile(
      leading: Icon(
        up == null ? Icons.system_update_alt : Icons.new_releases,
        color: up == null ? null : scheme.primary,
      ),
      title: const Text('检查更新'),
      subtitle: up == null ? null : Text('发现新版本 ${up.version}'),
      trailing: _checkingUpdate
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(
              AppInfo.version,
              style: TextStyle(
                  color: up == null ? scheme.onSurfaceVariant : scheme.primary),
            ),
      onTap: _checkingUpdate
          ? null
          : (up == null ? _manualCheckUpdate : () => _offerUpdate(up)),
    );
  }

  /// 启动时静默查一次。任何失败都当作"没有更新"，不弹任何东西。
  Future<void> _checkUpdate() async {
    final info = await UpdateService.check();
    if (!mounted) return;
    setState(() => _update = info);
  }

  /// 用户主动点的那次：这次要有反馈，不能像启动时那样静默
  Future<void> _manualCheckUpdate() async {
    setState(() => _checkingUpdate = true);
    final info = await UpdateService.check();
    if (!mounted) return;
    setState(() {
      _checkingUpdate = false;
      _update = info;
    });
    if (info == null) {
      _toast('已是最新版本（${AppInfo.version}）');
      return;
    }
    await _offerUpdate(info);
  }

  /// 提示有新版本，并给出下载入口。
  ///
  /// 不在 App 里下载安装：Android 要申请「安装未知应用」权限，iOS 的未签名
  /// IPA 又必须走 TrollStore。两条路都丢给系统浏览器最省事，也最不容易出错。
  Future<void> _offerUpdate(UpdateInfo info) async {
    final url = UpdateService.downloadUrlFor(info);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 ${info.version}'),
        content: Text(info.notes.isEmpty
            ? '当前 ${AppInfo.version}，可以更新到 ${info.version}。'
            : info.notes),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('以后再说'),
          ),
          if (url != null)
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _openDownload(url);
              },
              child: const Text('去下载'),
            ),
        ],
      ),
    );
  }

  Future<void> _openDownload(String url) async {
    try {
      // 不用 canLaunchUrl：它在 Android 11+ 要在 manifest 里声明 <queries>，
      // 直接 launch、失败就 catch，能省掉一处平台配置。
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok && mounted) _toast('打不开浏览器，请手动访问：$url');
    } catch (_) {
      if (mounted) _toast('打不开浏览器，请手动访问：$url');
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Widget _header() {
    if (_status == _Status.loggedIn && _profile != null) {
      return _profileHeader(_profile!);
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    IconData icon;
    Color color;
    String text;
    switch (_status) {
      case _Status.checking:
        icon = Icons.hourglass_empty;
        color = scheme.onSurfaceVariant;
        text = '正在检查登录状态…';
        break;
      case _Status.loggedIn:
        icon = Icons.check_circle;
        color = scheme.primary;
        text = '已登录';
        break;
      case _Status.loggedOut:
        icon = Icons.cancel;
        color = scheme.error;
        text = '未登录';
        break;
    }
    return Column(
      children: [
        CircleAvatar(
          radius: 40,
          backgroundColor: color.withOpacity(0.12),
          child: Icon(icon, size: 44, color: color),
        ),
        const SizedBox(height: 12),
        Text(text,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        if (_status == _Status.checking)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ),
      ],
    );
  }

  Widget _profileHeader(Profile p) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = p.name.isNotEmpty ? p.name : '同学';
    final initial = p.name.isNotEmpty ? p.name.characters.first : '?';
    return Column(
      children: [
        CircleAvatar(
          radius: 40,
          backgroundColor: scheme.primaryContainer,
          child: Text(
            initial,
            style: theme.textTheme.displaySmall
                ?.copyWith(color: scheme.onPrimaryContainer),
          ),
        ),
        const SizedBox(height: 12),
        Text(name,
            style:
                const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        if (p.studentId.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('学号：${p.studentId}',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
      ],
    );
  }

  List<Widget> _loggedInTiles() {
    final scheme = Theme.of(context).colorScheme;
    final p = _profile;
    final fields = p?.fields ?? const <MapEntry<String, String>>[];

    return [
      if (fields.isNotEmpty) ...[
        _sectionTitle('信息'),
        for (final e in fields) _infoRow(e.key, e.value),
      ],
      _sectionTitle('课表设置'),
      ListTile(
        leading: const Icon(Icons.calendar_month),
        title: const Text('学期'),
        subtitle: _terms.isEmpty ? const Text('登录后可选') : null,
        trailing: Text(_labelOf(_terms, _term, '默认'),
            style: TextStyle(color: scheme.onSurfaceVariant)),
        onTap: _terms.isEmpty ? null : _pickTerm,
      ),
      ListTile(
        leading: const Icon(Icons.location_city),
        title: const Text('校区'),
        subtitle: _campuses.isEmpty ? const Text('登录后可选') : null,
        trailing: Text(_labelOf(_campuses, _campus, '默认'),
            style: TextStyle(color: scheme.onSurfaceVariant)),
        onTap: _campuses.isEmpty ? null : _pickCampus,
      ),
      const Divider(),
      const ListTile(
        leading: Icon(Icons.storage_outlined),
        title: Text('数据来源'),
        subtitle: Text('广东工贸职业技术学院教务系统'),
      ),
      ListTile(
        leading: const Icon(Icons.refresh),
        title: const Text('刷新'),
        onTap: _check,
      ),
      ListTile(
        leading: Icon(Icons.logout, color: scheme.error),
        title: Text('退出登录', style: TextStyle(color: scheme.error)),
        onTap: _logout,
      ),
    ];
  }

  /// 一条信息行：左图标+字段名，右值。值用 Expanded 占满剩余宽度，
  /// 避免此前放在 ListTile.trailing 里被挤成一列竖排的问题。
  Widget _infoRow(String label, String value) {
    final theme = Theme.of(context);
    final subFg = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_iconFor(label), size: 20, color: subFg),
          const SizedBox(width: 16),
          SizedBox(
            width: 76,
            child: Text(label,
                style: theme.textTheme.bodyLarge?.copyWith(color: subFg)),
          ),
          Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyLarge),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  IconData _iconFor(String label) {
    if (label.contains('学院') || label.contains('系') || label.contains('院系')) {
      return Icons.account_balance;
    }
    if (label.contains('专业')) return Icons.school;
    if (label.contains('班级') || label.contains('行政班')) return Icons.groups;
    if (label.contains('年级')) return Icons.grade;
    if (label.contains('性别')) return Icons.wc;
    if (label.contains('学制') || label.contains('层次')) return Icons.timeline;
    if (label.contains('状态')) return Icons.verified_user;
    if (label.contains('电话') || label.contains('手机')) return Icons.phone;
    if (label.contains('邮箱')) return Icons.email;
    if (label.contains('日期') || label.contains('入学')) {
      return Icons.calendar_today;
    }
    if (label.contains('民族')) return Icons.public;
    if (label.contains('政治')) return Icons.flag;
    if (label.contains('籍贯') || label.contains('住址')) {
      return Icons.location_on;
    }
    return Icons.person_outline;
  }

  Widget _loginTile() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: FilledButton.icon(
        icon: const Icon(Icons.login),
        label: const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('去登录', style: TextStyle(fontSize: 16)),
        ),
        onPressed: _login,
      ),
    );
  }
}
