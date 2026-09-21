import 'package:flutter/material.dart';

import '../pages/login_page.dart';
import '../pages/password_login_page.dart';
import 'auth_store.dart';

/// 自动登录。
///
/// 只在用户勾了「自动登录」且本机存着密码时生效；每次启动 App 最多自动尝试
/// 一次，避免密码存错时反复弹认证页。失败就把控制权交回手动登录，不吞掉。
///
/// 会话 Cookie 还在有效期内时根本不会走到这里 —— 课表直接就能加载，
/// 所以「自动登录」实际只在登录态过期后才起作用，启动时不会闪一下认证页。
class AutoLogin {
  AutoLogin._();

  static bool _tried = false;
  static bool _suppressed = false;

  /// 用户主动退出登录后调用：本次启动内不再自动登录，
  /// 否则刚点完「退出」就被自动登回去。
  static void suppress() => _suppressed = true;

  /// 用户是否配置了自动登录（不看「本次是否已经试过」）。
  /// 用于退出登录时提示，以及判断该不该把密码留在本机。
  static Future<bool> isConfigured() async {
    if (!await AuthStore.getAutoLogin()) return false;
    final pwd = await AuthStore.getSavedPassword();
    return pwd != null && pwd.isNotEmpty;
  }

  /// 此刻是否真的会触发自动登录（还没试过、没被抑制、且已配置）
  static Future<bool> isEnabled() async {
    if (_tried || _suppressed) return false;
    return isConfigured();
  }

  /// 用本机保存的账号密码走一遍登录（复用 WebView 自动填充那条路）。
  static Future<LoginResult> attempt(BuildContext context) async {
    _tried = true; // 无论成败，本次启动都不再自动尝试
    final user = await AuthStore.getSavedUsername();
    final pwd = await AuthStore.getSavedPassword();
    if (user == null || user.isEmpty || pwd == null || pwd.isEmpty) {
      return const LoginResult.cancelled();
    }
    if (!context.mounted) return const LoginResult.cancelled();

    final res = await Navigator.of(context).push<LoginResult>(
      MaterialPageRoute(
        builder: (_) => LoginPage(autoUsername: user, autoPassword: pwd),
      ),
    );
    return res ?? const LoginResult.cancelled();
  }

  /// 需要登录时的统一入口：先悄悄自动登录，不行再打开登录页。
  /// 返回最终是否已登录。
  static Future<bool> ensureLoggedIn(BuildContext context) async {
    if (await isEnabled() && context.mounted) {
      final res = await attempt(context);
      if (res.ok) return true;
      // 自动登录没成（多半是密码改了）——落到手动登录，并把原因说清楚
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${res.message ?? '自动登录失败'}，'
                '请手动登录（可在下方取消「自动登录」）'),
          ),
        );
      }
    }
    if (!context.mounted) return false;
    return await Navigator.of(context).push<bool>(
          MaterialPageRoute(builder: (_) => const PasswordLoginPage()),
        ) ??
        false;
  }
}
