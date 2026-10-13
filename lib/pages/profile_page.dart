import 'package:flutter/material.dart';

import '../services/auth_store.dart';
import '../services/auto_login.dart';
import '../services/profile_service.dart';
import '../widgets/glass_dialog.dart';
import 'settings_page.dart';

/// "我的"页：登录状态 + 学籍信息。
///
/// **这一页只放"我是谁"。** 学期/校区/背景/深浅色/检查更新/关于/退出登录原来全在
/// 这里，现在搬去了「设置」（见 `settings_page.dart`）。理由不是"页太长"，而是那两
/// 类东西性质不同：学籍是**关于我的数据**，开关是**我要改 App 的行为**。学籍可能有
/// 十几行，开关全被淹在后面 —— 每次改个背景都得从一整屏个人信息里划过去。
///
/// 所以这一页现在只有：头像 / 姓名 / 学号 + 学籍字段 + 一个进设置的入口。
///
/// 没有顶栏：第一个东西本身就是身份，标题栏再写一遍"我的"纯属占位，还多切出一道
/// 横隔断。内容一直顶到状态栏底下，整页和玻璃是连着的 —— 和课表页"内容从顶栏底下
/// 穿过去"是同一个思路，只是这一页连顶栏都不需要。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

enum _Status { checking, loggedIn, loggedOut }

class _ProfilePageState extends State<ProfilePage> {
  _Status _status = _Status.checking;
  Profile? _profile;

  @override
  void initState() {
    super.initState();
    // 在别的页面登录/退出后，切回本页时自动重新检查
    AuthStore.authRevision.addListener(_onAuthChanged);
    _check();
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

  /// 只查学籍。学期/校区那套下拉项归设置页查 —— 那是两个不同的服务，没必要在一页里
  /// 为另一页的数据发请求。
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
      final profile = await ProfileService(cookie).fetch();
      if (!mounted || seq != _checkSeq) return;
      setState(() {
        _status = _Status.loggedIn;
        _profile = profile;
      });
    } catch (e) {
      if (!mounted || seq != _checkSeq) return;
      if (e == ProfileService.sessionExpired) {
        // 让出这一轮再清 cookie，免得上面那句 _check 重入时又被自己挡掉
        _checkSeq++;
        // 会话过期不是用户主动退出：课表缓存留着（见 AuthStore.clearSession），
        // 否则重登之前打开课表页会是一片空白。
        //
        // 带上这张失败的票：本页和课表页在同一个 IndexedStack 里，启动时同时发
        // 请求、同时判出失效。要是课表页那边已经先一步自动重登、换上了新票，这里
        // 再去清就会把**刚存进来的新票删掉**，等于把用户从已经登好的状态里踢出去，
        // 只能手动登录。
        final cleared = await AuthStore.clearSession(failedCookie: cookie);
        if (!mounted) return;
        if (!cleared) {
          // 票换新了，这次失效是过期的旧消息：拿新票重查一次
          _check();
          return;
        }
        setState(() {
          _status = _Status.loggedOut;
          _profile = null;
        });
      } else {
        // 网络抖动之类的：cookie 还在，就当已登录，只是学籍这次没取到
        setState(() => _status = _Status.loggedIn);
      }
    }
  }

  Future<void> _login() async {
    final ok = await AutoLogin.ensureLoggedIn(context);
    if (ok) _check();
  }

  /// 退出登录。
  ///
  /// 从设置页搬到这一页（用户指定顺序：数据来源 → 设置 → 退出登录）。它本来就更配
  /// 这一页 —— 这页显示的就是登录状态，退完就地刷成未登录态，不用再切回设置页。
  Future<void> _logout() async {
    final autoOn = await AutoLogin.isConfigured();
    if (!mounted) return;
    final confirm = await showGlassDialog<bool>(
      context: context,
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
    );
    if (confirm != true) return;
    // 登录态**和课表缓存**一起清。这是"退出登录"和"会话过期"的关键区别：
    // 前者是用户的本意，课表不该留（连内存里那份也清，见 `AuthStore.logoutRevision`
    // 和课表页的 `_onLogout`）；后者课表还有效，要留着（见 `AuthStore.clearSession`）。
    await AuthStore.clear();
    // 刚点完退出就被自动登回去太别扭：本次启动内不再自动登录
    AutoLogin.suppress();
    // 不用手动 setState：`AuthStore.clear()` 已经自增 authRevision，本页监听着，
    // `_check()` 会自己刷成未登录态。
  }

  // ---------- 关于入场动画 ----------
  //
  // **没有了，是故意删掉的。** 和设置页一样。
  //
  // 原来是每行往上挪 8px（更早还叠着 opacity 0→1 的淡入），按序号依次错开，总时长
  // 260ms。实机 iOS 上用户连着两轮反馈「点进新页面会先看到上一个页面一闪而过」和
  // 「动画还是有延迟」—— 上一轮只删了淡入、留着位移和错开，还是不行。问题在**错开**
  // 本身：内容不是一次到位，而是一行一行排队出现，那就是"延迟"。
  //
  // 现在列表原样返回：推入的这一帧就有全部内容。

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

  /// 已登录时这一段只有学籍。可改的东西全在设置页。
  List<Widget> _loggedInTiles() {
    final p = _profile;
    final fields = p?.fields ?? const <MapEntry<String, String>>[];
    if (fields.isEmpty) return const [];
    return [
      _sectionTitle('信息'),
      for (final e in fields) _infoRow(e.key, e.value),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 「我的」这一页没有顶栏（原因见类注释）。
      body: Builder(
        builder: (ctx) {
          // 在 Scaffold **之下**读：`build()` 的 context 在它上面，拿到的是没被
          // Scaffold 调过的那份内边距。没有顶栏了，但**底栏槽位的高度仍在这一份
          // 里**，滚动区得靠它避开悬浮底栏。
          final media = MediaQuery.of(ctx);
          return RefreshIndicator(
            onRefresh: _check,
            // 不偏这一下的话，下拉的转圈会出现在状态栏底下被挡住
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
                children: [
                  // 头像/姓名这一段原来只让开 24，视觉上是"贴着状态栏"。让开的这一截
                  const SizedBox(height: 56),
                  _header(),
                  const SizedBox(height: 24),
                  if (_status == _Status.loggedIn) ..._loggedInTiles(),
                  if (_status == _Status.loggedOut) _loginTile(),
                  const Divider(),
                  // 顺序是用户指定的：数据来源 → 设置 → 退出登录
                  const ListTile(
                    leading: Icon(Icons.storage_outlined),
                    title: Text('数据来源'),
                    subtitle: Text('广东工贸职业技术学院教务系统'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.settings_outlined),
                    title: const Text('设置'),
                    subtitle: const Text('外观、课表、关于'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsPage()),
                    ),
                  ),
                  // 「退出登录」只在已登录时才出现：没登录时上面已经是「去登录」，
                  // 再挂一条「退出登录」自相矛盾。
                  if (_status == _Status.loggedIn)
                    ListTile(
                      leading: Icon(Icons.logout,
                          color: Theme.of(context).colorScheme.error),
                      title: Text('退出登录',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                      onTap: _logout,
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}