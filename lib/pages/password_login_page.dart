import 'package:flutter/material.dart';

import '../config.dart';
import '../services/auth_store.dart';
import 'login_page.dart';

/// 自绘登录页。
///
/// 主路径：把账号密码交给 WebView，**模拟人手动输入两个输入框再点登录**
/// （见 [LoginPage] 的自动填充模式）。加密/跳转/Cookie 全由浏览器内核完成，
/// 最稳；需要验证码时才把网页露出来让用户接管。
///
/// 备用路径：企业微信扫码（见 [LoginPage] 的 initialUrl 模式）。二维码必须
/// 一直看得见，所以那一路网页全程显示、不遮罩也不自动填充。
class PasswordLoginPage extends StatefulWidget {
  const PasswordLoginPage({super.key});

  @override
  State<PasswordLoginPage> createState() => _PasswordLoginPageState();
}

class _PasswordLoginPageState extends State<PasswordLoginPage> {
  final _userCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  bool _obscure = true;

  /// 有登录页正压在上面（自动模式或扫码）。用来防连点重复 push。
  bool _loginOpen = false;
  bool _savePwd = false;
  bool _autoLogin = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final u = await AuthStore.getSavedUsername();
    final savePwd = await AuthStore.getRememberPassword();
    final auto = await AuthStore.getAutoLogin();
    final pwd = savePwd ? await AuthStore.getSavedPassword() : null;
    if (!mounted) return;
    setState(() {
      if (u != null) _userCtrl.text = u;
      if (pwd != null) _pwdCtrl.text = pwd;
      _savePwd = savePwd;
      _autoLogin = auto && savePwd; // 不存密码就谈不上自动登录
    });
  }

  /// 登录成功后落盘：勾了才存密码，没勾就把旧的清掉。
  /// 只在成功后写，避免把打错的密码存下来。
  Future<void> _persistCredentials(String user, String pwd) async {
    await AuthStore.saveUsername(user);
    await AuthStore.saveRememberPassword(_savePwd);
    if (_savePwd) {
      await AuthStore.savePassword(pwd);
    } else {
      await AuthStore.clearSavedPassword();
    }
    await AuthStore.saveAutoLogin(_autoLogin && _savePwd);
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  /// 主路径：交给 WebView 自动填充并提交（模拟人输入）。
  /// 全程只显示"转圈"的框；账号密码错会带着原因退回来在这里原地提示，
  /// 只有出现验证码才把网页露出来让用户接管。
  Future<void> _submit() async {
    if (_loginOpen) return;
    final user = _userCtrl.text.trim();
    final pwd = _pwdCtrl.text;
    if (user.isEmpty || pwd.isEmpty) {
      setState(() => _error = '请输入账号和密码');
      return;
    }
    setState(() {
      _loginOpen = true;
      _error = null;
    });

    final res = await Navigator.of(context).push<LoginResult>(
      MaterialPageRoute(
        builder: (_) => LoginPage(autoUsername: user, autoPassword: pwd),
      ),
    );
    if (!mounted) return;
    if (res != null && res.ok) {
      await _persistCredentials(user, pwd);
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _loginOpen = false;
      // res == null 是用户自己按了返回，不算失败，不弹错误
      if (res != null) _error = res.message ?? '登录失败，请重试';
    });
  }

  /// 备用路径：企业微信扫码。
  ///
  /// 这一路没有账号密码可填，二维码也必须一直看得见，所以直接进
  /// [LoginPage] 的扫码入口（网页全程显示、不遮罩、不自动填充）。
  Future<void> _qrLogin() async {
    if (_loginOpen) return;
    setState(() {
      _loginOpen = true;
      _error = null;
    });

    final res = await Navigator.of(context).push<LoginResult>(
      MaterialPageRoute(
        builder: (_) => LoginPage(initialUrl: AppConfig.loginQrUrl),
      ),
    );
    if (!mounted) return;
    if (res != null && res.ok) {
      // 扫码这条路没经过"密码"这一步：不写密码，也不动「保存密码 / 自动登录」
      // 两个勾 —— 免得把一份从没被验证过的密码存成"已保存"，之后自动登录
      // 拿着它反复去撞，反而把账号推进验证码状态。用户名照存。
      final u = _userCtrl.text.trim();
      if (u.isNotEmpty) await AuthStore.saveUsername(u);
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _loginOpen = false;
      if (res != null) _error = res.message ?? '登录失败，请重试';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('账号密码登录')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 12),
            Center(
              child: Image.asset('assets/icon/app_logo.png',
                  width: 80, height: 80),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text('GMPluse',
                  style: Theme.of(context).textTheme.headlineSmall),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text('统一身份认证登录',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _userCtrl,
              enabled: !_loginOpen,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '学号 / 工号',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pwdCtrl,
              enabled: !_loginOpen,
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _loginOpen ? null : _submit(),
              decoration: InputDecoration(
                labelText: '密码',
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: CheckboxListTile(
                    value: _savePwd,
                    onChanged: _loginOpen
                        ? null
                        : (v) => setState(() {
                              _savePwd = v ?? false;
                              // 不保存密码就无从自动登录
                              if (!_savePwd) _autoLogin = false;
                            }),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('保存密码',
                        style: TextStyle(fontSize: 14)),
                  ),
                ),
                Expanded(
                  child: CheckboxListTile(
                    value: _autoLogin,
                    onChanged: _loginOpen
                        ? null
                        : (v) => setState(() {
                              _autoLogin = v ?? false;
                              // 自动登录依赖已存的密码，顺手把「保存密码」也勾上
                              if (_autoLogin) _savePwd = true;
                            }),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('自动登录',
                        style: TextStyle(fontSize: 14)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _loginOpen ? null : _submit,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: _loginOpen
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.onPrimary),
                      )
                    : const Text('登录', style: TextStyle(fontSize: 16)),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _loginOpen ? null : _qrLogin,
              icon: const Icon(Icons.qr_code_2, size: 18),
              label: const Text('企业微信扫码登录'),
            ),
          ],
        ),
      ),
    );
  }
}
