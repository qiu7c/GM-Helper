import 'package:flutter/material.dart';

import '../pages/login_page.dart';
import '../pages/password_login_page.dart';
import 'auth_store.dart';

/// 自动登录。
///
/// 只在用户勾了「自动登录」且本机存着密码时生效。失败就把控制权交回手动登录，
/// 不吞掉。
///
/// 会话 Cookie 还在有效期内时根本不会走到这里 —— 课表直接就能加载，
/// 所以「自动登录」实际只在登录态过期后才起作用，启动时不会闪一下认证页。
///
/// 关于"一次启动能自动登录几次"，这里分两种失败来对待：
///  - **失败**（密码错 / 要验证码）：封口，本次启动不再自动尝试。否则会拿一个
///    错密码反复去撞，把账号推进"必须输验证码"的状态。
///  - **成功**：不封口，只记次数（上限 [_maxSuccesses]）。密码刚被证明是对的，
///    之后再需要（比如票又过期了）就该能默默登上。
///
/// 早先的写法是"本次启动无论成败只试一次"。那样只要第一次成功之后出任何岔子
/// （最典型的就是并发请求把新票删了，见 [AuthStore.clearSession]），用户就被
/// 丢到账号密码登录页 —— 而自动登录明明是好的。上限那几次是防"登进去 → 立刻
/// 又失效 → 再登"这种来回把认证服务打爆。
class AutoLogin {
  AutoLogin._();

  /// 本次启动自动登录成功的次数上限
  static const int _maxSuccesses = 3;
  static int _successes = 0;

  /// 已经失败过一次（密码错/要验证码）
  static bool _failed = false;

  static bool _suppressed = false;

  /// 正在跑的那次自动登录。几条路可能同时要登录（课表页在弹、「我的」页
  /// 也在弹），共用同一次尝试，别把登录页推起来两层。
  static Future<LoginResult>? _inflight;

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

  /// 此刻是否真的会触发自动登录（密码对过、没失败过、没被抑制、且已配置）
  static Future<bool> isEnabled() async {
    if (_suppressed || _failed || _successes >= _maxSuccesses) return false;
    return isConfigured();
  }

  /// 用本机保存的账号密码走一遍登录（复用 WebView 自动填充那条路）。
  static Future<LoginResult> attempt(BuildContext context) {
    return _inflight ??=
        _run(context).whenComplete(() => _inflight = null);
  }

  static Future<LoginResult> _run(BuildContext context) async {
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
    final r = res ?? const LoginResult.cancelled();
    if (r.ok) {
      _successes++;
    } else if (r.message != null) {
      // 明确的失败（密码错、要验证码）：封口，别反复撞
      _failed = true;
    }
    // 用户自己按返回退出来（message == null）：不算失败，也不占额度
    return r;
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
