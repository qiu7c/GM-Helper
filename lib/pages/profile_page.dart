import 'package:flutter/material.dart';

import '../models/course.dart';
import '../services/auth_store.dart';
import '../services/auto_login.dart';
import '../services/profile_service.dart';
import '../services/schedule_prefs.dart';
import '../services/schedule_service.dart';
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
        await AuthStore.clearSession();
        if (!mounted) return;
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
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(title,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          ...opts.map((o) => ListTile(
                title: Text(o.label),
                trailing: o.value == current
                    ? const Icon(Icons.check, color: Colors.green)
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
      appBar: AppBar(title: const Text('我的')),
      body: RefreshIndicator(
        onRefresh: _check,
        child: ListView(
          children: [
            const SizedBox(height: 24),
            _header(),
            const SizedBox(height: 24),
            if (_status == _Status.loggedIn) ..._loggedInTiles(),
            if (_status == _Status.loggedOut) _loginTile(),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('关于'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AboutPage()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    if (_status == _Status.loggedIn && _profile != null) {
      return _profileHeader(_profile!);
    }

    IconData icon;
    Color color;
    String text;
    switch (_status) {
      case _Status.checking:
        icon = Icons.hourglass_empty;
        color = Colors.grey;
        text = '正在检查登录状态…';
        break;
      case _Status.loggedIn:
        icon = Icons.check_circle;
        color = Colors.green;
        text = '已登录';
        break;
      case _Status.loggedOut:
        icon = Icons.cancel;
        color = Colors.redAccent;
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
            style:
                const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
    final name = p.name.isNotEmpty ? p.name : '同学';
    final initial = p.name.isNotEmpty ? p.name.characters.first : '?';
    return Column(
      children: [
        CircleAvatar(
          radius: 40,
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(
            initial,
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
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
                style: const TextStyle(color: Colors.grey, fontSize: 14)),
          ),
      ],
    );
  }

  List<Widget> _loggedInTiles() {
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
            style: const TextStyle(color: Colors.grey)),
        onTap: _terms.isEmpty ? null : _pickTerm,
      ),
      ListTile(
        leading: const Icon(Icons.location_city),
        title: const Text('校区'),
        subtitle: _campuses.isEmpty ? const Text('登录后可选') : null,
        trailing: Text(_labelOf(_campuses, _campus, '默认'),
            style: const TextStyle(color: Colors.grey)),
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
        leading: const Icon(Icons.logout, color: Colors.redAccent),
        title: const Text('退出登录',
            style: TextStyle(color: Colors.redAccent)),
        onTap: _logout,
      ),
    ];
  }

  /// 一条信息行：左图标+字段名，右值。值用 Expanded 占满剩余宽度，
  /// 避免此前放在 ListTile.trailing 里被挤成一列竖排的问题。
  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_iconFor(label), size: 20, color: Colors.grey),
          const SizedBox(width: 16),
          SizedBox(
            width: 76,
            child: Text(label,
                style: const TextStyle(color: Colors.grey, fontSize: 14)),
          ),
          Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 14)),
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
