import 'package:flutter/material.dart';

import '../services/auth_store.dart';
import '../services/cas_login_service.dart';
import 'login_page.dart';

/// 自绘账号密码登录页。
///
/// 主路径：把账号密码交给 WebView，**模拟人手动输入两个输入框再点登录**
/// （见 [LoginPage] 的自动填充模式）。加密/跳转/Cookie 全由浏览器内核完成，
/// 最稳；页面可见，需要验证码时用户能直接接管。
///
/// 备用路径：纯 HTTP 直连登录（不打开网页），失败时可在下方展开排错日志。
class PasswordLoginPage extends StatefulWidget {
  const PasswordLoginPage({super.key});

  @override
  State<PasswordLoginPage> createState() => _PasswordLoginPageState();
}

class _PasswordLoginPageState extends State<PasswordLoginPage> {
  final _userCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  bool _savePwd = false;
  bool _autoLogin = false;
  String? _error;
  List<String> _trace = [];

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
    final user = _userCtrl.text.trim();
    final pwd = _pwdCtrl.text;
    if (user.isEmpty || pwd.isEmpty) {
      setState(() => _error = '请输入账号和密码');
      return;
    }
    setState(() {
      _error = null;
      _trace = [];
    });

    final res = await Navigator.of(context).push<LoginResult>(
      MaterialPageRoute(
        builder: (_) => LoginPage(autoUsername: user, autoPassword: pwd),
      ),
    );
    if (!mounted) return;
    if (res == null) return; // 用户自己按返回
    if (!res.ok) {
      // 账号密码错之类：原地提示，不存这份错的凭证
      setState(() => _error = res.message ?? '登录失败，请重试');
      return;
    }
    await _persistCredentials(user, pwd);
    if (mounted) Navigator.of(context).pop(true);
  }

  /// 备用路径：不打开网页，用 HTTP 直接走一遍 CAS
  Future<void> _directLogin() async {
    final user = _userCtrl.text.trim();
    final pwd = _pwdCtrl.text;
    if (user.isEmpty || pwd.isEmpty) {
      setState(() => _error = '请输入账号和密码');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    final service = CasLoginService()..debugLog = true;
    try {
      final cookie = await service.login(user, pwd);
      await AuthStore.saveCookie(cookie);
      await _persistCredentials(user, pwd);
      if (mounted) Navigator.of(context).pop(true);
    } on CasLoginException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _trace = service.trace;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '登录失败：$e';
          _trace = service.trace;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
            const Center(
              child: Text('GMPluse',
                  style:
                      TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 4),
            const Center(
              child: Text('统一身份认证登录',
                  style: TextStyle(color: Colors.grey)),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _userCtrl,
              enabled: !_loading,
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
              enabled: !_loading,
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _loading ? null : _submit(),
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
                    onChanged: _loading
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
                    onChanged: _loading
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
            if (_savePwd)
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  '密码保存在本机 App 私有目录（明文，与会话 Cookie 同级）；'
                  '未越狱 / 未 root 的设备上其它应用读不到。',
                  style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.4),
                ),
              ),
            const SizedBox(height: 4),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  style: const TextStyle(color: Colors.redAccent)),
              if (_trace.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('查看登录过程（排错用）',
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      color: Colors.black.withOpacity(0.04),
                      child: SelectableText(
                        _trace.join('\n'),
                        style: const TextStyle(
                            fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ),
                  ],
                ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _loading ? null : _submit,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('登录', style: TextStyle(fontSize: 16)),
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '登录全程只显示进度，不会露出网页；\n'
                '只有需要输入验证码时才切到认证页面。\n'
                '勾选「自动登录」后，登录态过期时会在启动时自动登一次。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.5),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _loading ? null : _directLogin,
              icon: const Icon(Icons.bolt, size: 18),
              label: const Text('不打开网页，直连登录（实验）'),
            ),
          ],
        ),
      ),
    );
  }
}
