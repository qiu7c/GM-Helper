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
      // 自动登录全程**不占屏**。
      //
      // 关键在 `opaque: false`：路由不透明的话，这条登录页会盖住课表，用户
      // 看到一个"正在登录"的界面 —— 而那正是要去掉的东西。透明路由下，用户
      // 看到的始终是下面那一页（课表）自己的加载状态，直到自动登录成功、
      // 或者出了问题需要他接管（见 LoginPage._reveal）才现出来。
      //
      // 过渡动画也设成 0：一个看不见的页面没什么好滑的，有动画反而会让下面
      // 那一页跟着抖一下。
      //
      // 用 `_SilentLoginRoute` 而不是直接的 `PageRouteBuilder`：光有
      // `opaque: false` 只做到"看得见"，底下那一页还是点不动。原因见那个类。
      _SilentLoginRoute<LoginResult>(
        pageBuilder: (_, __, ___) =>
            LoginPage(autoUsername: user, autoPassword: pwd),
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

/// 静默登录专用的路由：`opaque: false` 让下面的课表继续可见，**而且不装遮罩**。
///
/// 为什么不能直接用 `PageRouteBuilder`：`ModalRoute.createOverlayEntries()` 里把
/// 遮罩写死了，任何 `ModalRoute` 都一定会装一个 `ModalBarrier`（routes.dart:2052）。
/// 而它在 3.24.5 里是 `RawGestureDetector(behavior: HitTestBehavior.opaque)`
/// （modal_barrier.dart:448-451）—— `barrierColor: null` 只让它**看不见**，命中
/// 判定照旧把事件全吃掉。更别扭的是 `ModalBarrier` 在 `dismissible == false` 时
/// 把点击处理成 `SystemSound.play(SystemSoundType.alert)`
/// （modal_barrier.dart:228-234，`PageRouteBuilder` 的 `barrierDismissible` 默认
/// 正是 false）。
///
/// 于是自动登录那几秒的真实观感是：课表看得见、**却点不动也划不动，点一下还响
/// 一声系统提示音** —— 就是「像卡死一样」。而这段代码的意图（见上面 `opaque`
/// 那段注释）一直是"底下那一页继续可见**且可用**"，只是被遮罩挡掉了后半句。
///
/// 修法：覆写 `buildModalBarrier()` —— 它是 `ModalRoute` 上公开的方法，源码注释
/// 写着 "subclasses can override this method to create their own barrier"。返回
/// 一个零尺寸的盒子：不画、不挡。
///
/// 落回手动登录时 `LoginPage` 会整块换成可交互的界面（不再走 `_buildSilentBody`），
/// 所以不存在"登录页露出来了但点不进去"的问题。
class _SilentLoginRoute<T> extends PageRouteBuilder<T> {
  _SilentLoginRoute({required super.pageBuilder})
      : super(
          opaque: false,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        );

  @override
  Widget buildModalBarrier() => const SizedBox.shrink();
}
