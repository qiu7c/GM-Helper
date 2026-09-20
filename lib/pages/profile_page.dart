import 'package:flutter/material.dart';

import '../services/auth_store.dart';
import '../services/profile_service.dart';
import 'password_login_page.dart';

/// "我的"页：检查登录状态，展示详细学籍信息，支持退出登录。
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
    _check();
  }

  /// 检查登录状态并拉取个人信息：本地有 Cookie 且能成功请求才算真正登录
  Future<void> _check() async {
    setState(() => _status = _Status.checking);

    final cookie = await AuthStore.getCookie();
    if (cookie == null || cookie.isEmpty) {
      setState(() => _status = _Status.loggedOut);
      return;
    }

    try {
      final profile = await ProfileService(cookie).fetch();
      if (!mounted) return;
      setState(() {
        _status = _Status.loggedIn;
        _profile = profile;
      });
    } catch (e) {
      if (!mounted) return;
      if (e == ProfileService.sessionExpired) {
        await AuthStore.clear();
        setState(() => _status = _Status.loggedOut);
      } else {
        // 网络等其它错误：本地有 Cookie 就先当已登录，避免误判
        setState(() => _status = _Status.loggedIn);
      }
    }
  }

  Future<void> _login() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const PasswordLoginPage()),
    );
    if (ok == true) _check();
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出登录吗？退出后需重新登录才能查看课表。'),
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
      setState(() {
        _status = _Status.loggedOut;
        _profile = null;
      });
    }
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

  /// 已登录时的头部：头像 + 姓名 + 学号
  Widget _profileHeader(Profile p) {
    final name = p.name.isNotEmpty ? p.name : '同学';
    final initial = p.name.isNotEmpty ? p.name.characters.first : '?';
    return Column(
      children: [
        CircleAvatar(
          radius: 40,
          backgroundColor:
              Theme.of(context).colorScheme.primaryContainer,
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
        _sectionTitle('学籍信息'),
        for (final e in fields)
          ListTile(
            dense: true,
            leading: Icon(_iconFor(e.key), size: 20, color: Colors.grey),
            title: Text(e.key),
            trailing: Flexible(
              child: Text(
                e.value,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        const Divider(),
      ],
      const ListTile(
        leading: Icon(Icons.info_outline),
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
        title:
            const Text('退出登录', style: TextStyle(color: Colors.redAccent)),
        onTap: _logout,
      ),
    ];
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
