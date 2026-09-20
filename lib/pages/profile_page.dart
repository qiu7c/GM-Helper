import 'package:flutter/material.dart';

import '../config.dart';
import '../services/auth_store.dart';
import '../services/schedule_service.dart';
import 'login_page.dart';

/// "我的"页：检查登录状态，展示学期/校区信息，支持退出登录。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

enum _Status { checking, loggedIn, loggedOut }

class _ProfilePageState extends State<ProfilePage> {
  _Status _status = _Status.checking;
  String? _term;

  @override
  void initState() {
    super.initState();
    _check();
  }

  /// 检查登录状态：本地有 Cookie 且能成功请求课表接口才算真正登录
  Future<void> _check() async {
    setState(() => _status = _Status.checking);

    final cookie = await AuthStore.getCookie();
    if (cookie == null || cookie.isEmpty) {
      setState(() => _status = _Status.loggedOut);
      return;
    }

    try {
      final result = await ScheduleService(cookie).fetch();
      if (!mounted) return;
      setState(() {
        _status = _Status.loggedIn;
        _term = result.selectedTerm ?? _term;
      });
    } catch (e) {
      if (!mounted) return;
      if (e == ScheduleService.sessionExpired) {
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
      MaterialPageRoute(builder: (_) => const LoginPage()),
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
      setState(() => _status = _Status.loggedOut);
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
                width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
      ],
    );
  }

  List<Widget> _loggedInTiles() {
    return [
      if (_term != null && _term!.isNotEmpty)
        ListTile(
          leading: const Icon(Icons.calendar_month),
          title: const Text('当前学期'),
          trailing: Text(_term!),
        ),
      const ListTile(
        leading: Icon(Icons.info_outline),
        title: Text('数据来源'),
        subtitle: Text('广东工贸职业技术学院教务系统'),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.refresh),
        title: const Text('刷新登录状态'),
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
