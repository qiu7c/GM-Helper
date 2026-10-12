import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// 毛玻璃的公共件，悬浮底栏和玻璃顶栏都从这儿取。
///
/// 单独抽一份的理由和 `timetable_grid` 一样：底栏和顶栏必须是同一种材质，
/// 两处各写一遍迟早会写出两种模糊度、两种不透明度，凑在一起就露馅。
///
/// 圆角之类的尺寸 token 在 `app_theme.dart`，这里只管玻璃本身。

/// 一块毛玻璃。
///
/// `ClipRRect` 是**必需**的，不是修饰：`BackdropFilter` 不裁的话会把滤镜作用到
/// 整个背景上，屏幕下半截跟着一起糊。
///
/// 「液态」感靠三样东西，少一样都会退回成一块半透明的塑料板：
///
///  1. **斜向渐变，而不是纯色填充。** 纯色平板没有厚度；从左上到右下压一层
///     渐变，玻璃才像有体积。
///  2. **一圈镜面描边**：上缘亮、下缘暗，模拟玻璃边缘的折射高光。这一笔最出
///     效果 —— 之前的 `Border.all` 是一条颜色均一的线，读起来是"印刷边框"，
///     不是"光打在边上"。现在是**两道**（外缘渐变 + 内缘上半段一道极淡的白线），
///     玻璃的"厚度"就是这两道给的。
///  3. **一道斜向光泽**（sheen）：白光从左上方斜着扫过去，只占左上那一角就淡掉。
///     描边管"边"，这层管"面" —— 少了它，面板中间是平的。
///  4. **深浅色各自调过强度。** 白描边压在浅色玻璃上会消失，深色下同样的白
///     又太扎眼，所以两组数值分开给。
///
/// 镜面描边只能自己画（[CustomPainter]）：`BoxDecoration` 不允许"不均匀边框 +
/// 圆角"共存（见 [border]），而我们要的正是一圈**带渐变**的描边，用 [Border]
/// 表达不出来。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    this.child,
    this.borderRadius,
    this.border,
    this.fillOpacity = AppTheme.glassFill,
    this.blur = AppTheme.glassBlur,
  });

  final Widget? child;

  /// 圆角，同时作用于裁剪和描边。不传就是直角（玻璃顶栏用直角，它要贴满顶边）。
  ///
  /// 传了才会画镜面描边 —— 顶栏贴边、要的是那条发丝线，给它描一圈框会很怪。
  final BorderRadius? borderRadius;

  /// 描边。
  ///
  /// ⚠ `BoxDecoration` 只允许**均匀边框**跟圆角共存，不均匀的（比如只有底边那条
  /// 发丝线）配上 `borderRadius` 会直接断言失败。所以顶栏传底边线时**不能**传
  /// `borderRadius`。
  final BoxBorder? border;

  final double fillOpacity;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final broadcast = borderRadius ?? BorderRadius.zero;

    // 上端要"看得出是玻璃"（别糊成一块实心板），下端要"字还读得清"。
    //
    // ⚠ 这两个余量**必须按比例跟着 AppTheme.glassFill 走**，不能用固定加减。
    // 固定加减已经踩过两次坑：基数 0.78 时写的「-0.16，且不低于 0.62」，等基数
    // 降到 0.62 就把下端钳得**比上端还高**，渐变整个反过来；基数再降到 0.34 时
    // 「-0.18，且不低于 0.30」又把上下端直接钳成相等，渐变被压平。
    //
    // 改成乘系数之后，不管基数怎么调都成立：上端恒定比基数实 1.2 倍、下端恒定
    // 比基数淡 0.55 倍，渐变永远有方向、永远不会翻。
    final top = (fillOpacity * 1.20).clamp(0.0, 0.92);
    final bottom = (fillOpacity * 0.55).clamp(0.0, 0.92);

    // 只有"浮起来"的面板才加光泽和镜面描边。顶栏是贴边的一整条，给它描一圈框、
    // 压一道斜光都不像玻璃，像脏了。判据跟下面两处共用同一个。
    final floating = borderRadius != null;

    return ClipRRect(
      borderRadius: broadcast,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.surface.withOpacity(top),
                scheme.surface.withOpacity(bottom),
              ],
            ),
            borderRadius: borderRadius,
            border: border,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: floating
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        // ⚠ 这道光泽**不能给太重**。它和模糊是此消彼长的：光泽越亮，这块玻璃
                    // 越像一片磨砂白塑料板，"背后透过来的是什么"就越看不出来。
                    // 原来 0.22 的时候，底栏那块小胶囊几乎被它洗成实心的。
                    Colors.white.withOpacity(dark ? 0.06 : 0.12),
                        Colors.white.withOpacity(0.02),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.28, 0.62],
                    )
                  : null,
              borderRadius: borderRadius,
            ),
            child: CustomPaint(
              foregroundPainter: floating
                  ? _LiquidRim(borderRadius: broadcast, dark: dark)
                  : null,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 玻璃边缘那道镜面高光（见 [GlassPanel] 的说明）。
///
/// 一条**带渐变**的描边：左上最亮（光从那儿来），中段几乎透明，到右下变成一层
/// 极淡的阴影。于是面板看起来是"立"在内容上的，而不是贴上去的一块色板。
class _LiquidRim extends CustomPainter {
  const _LiquidRim({required this.borderRadius, required this.dark});

  final BorderRadius borderRadius;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // 往里缩半像素：描边以路径为中心线画，不缩的话一半宽度会被外面的 ClipRRect 裁掉，
    // 高光只剩一半亮度
    final rrect = borderRadius.toRRect(rect).deflate(0.5);

    // 外缘：左上最亮 → 中段几乎透明 → 右下压一层淡阴影
    final outer = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          // ⚠ 描边也调淡过一轮。原来浅色模式左上角是 0.78 的白 —— 在一整条顶栏上
          // 还行，但在底栏那块 224×60 的小胶囊上，这条边占的比例太大，整块读起来
          // 就是"一条白线围着的实心板"，同样把透明度盖掉了。留一圈能看出边缘就够。
          Colors.white.withOpacity(dark ? 0.30 : 0.56),
          Colors.white.withOpacity(dark ? 0.08 : 0.14),
          Colors.black.withOpacity(dark ? 0.20 : 0.08),
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(rect);
    canvas.drawRRect(rrect, outer);

    // 内缘：再压一道极淡的白线，**只有上半段**，往下淡出。
    //
    // 玻璃有"厚度"是因为边缘有两道反光；只有一道会读成印刷描边。下半段不给，
    // 否则底面也发亮，整块看起来像塑料。
    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withOpacity(dark ? 0.10 : 0.20),
          Colors.transparent,
        ],
        stops: const [0.0, 0.5],
      ).createShader(rect);
    canvas.drawRRect(rrect.deflate(1.5), inner);
  }

  @override
  bool shouldRepaint(covariant _LiquidRim old) =>
      old.borderRadius != borderRadius || old.dark != dark;
}

/// 玻璃顶栏。
///
/// 两个作用，缺一不可：
///
///  1. **干掉滚动时的变色**。M3 默认 `scrolledUnderElevation: 3`，内容一滚到
///     顶栏底下，`effectiveBackgroundColor` 就从 `surface` 切成 `surfaceContainer`
///     —— 这就是用户说的"顶栏变色，很别扭"。四个属性（透明底 + 透明 tint +
///     透明阴影 + elevation 归零）关掉它，换成常驻的一条发丝线。
///  2. 让内容真的从**底下穿过去**。这需要页面 Scaffold 开
///     `extendBodyBehindAppBar: true`，否则内容从顶栏下沿开始，玻璃背后是块
///     纯色，模糊等于白做。
///
/// `flexibleSpace` 是 AppBar 内部 `Stack` 里**先画**的那个，会铺满整个矩形
/// （含状态栏区、以及 `bottom` 那块），所以放这儿。
///
/// ⚠ 但 AppBar 自己的 `Material` 画在它**后面** —— 所以 `backgroundColor` 必须是
/// 全透明：留一个不透明色的话，模糊的背景就是那块纯色，玻璃看不出来。
PreferredSizeWidget glassAppBar({
  required BuildContext context,
  Widget? title,
  Widget? leading,
  bool automaticallyImplyLeading = true,
  double? titleSpacing,
  List<Widget>? actions,
  PreferredSizeWidget? bottom,
  double? toolbarHeight,
  bool frosted = true,
}) {
  return AppBar(
    // 这四个合起来做到"永不变色"
    backgroundColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    shadowColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0,
    automaticallyImplyLeading: automaticallyImplyLeading,
    leading: leading,
    titleSpacing: titleSpacing,
    actions: actions,
    bottom: bottom,
    // 不传就沿用主题/框架默认，免得无声无息改掉原有高度
    toolbarHeight: toolbarHeight,
    // ⚠ 这里是 `const`。删描边之后所有参数都成了常量，不加 const 会触发
    // prefer_const_constructors（这是我删描边时顺手引进的一条 lint）
    //
    // `frosted: false` 时**整块玻璃都不画**，顶栏只剩浮在页面底上的标题和按钮。
    // 课表页要的就是这个：它上面没有别的内容，一块玻璃板只会切出"另一层"。
    // 别的页面（关于、更新日志…）仍留着玻璃，因为它们是从别处推进来的二级页，
    // 需要一条认得出的顶栏边界。
    flexibleSpace: frosted
        ? const GlassPanel(
            // 顶栏**不要**任何描边/发丝线了。
            //
            // 原来这里是一条 outlineVariant 的底边线 —— 那就是"分割线"本线：它把顶栏
            // 和下面的课表切成两块。现在顶栏、上课状态、课表要**融为一体**，靠的是玻璃
            // 的透光和渐变，而不是一条界。所以这里连 `border` 都不传。
            //
            // 也因此不存在"不均匀边框配圆角会断言失败"那个坑了（见 `border` 的注释）。
            //
            // 撑满整个矩形。不撑的话 DecoratedBox 没内容就缩成 0 高，玻璃会消失
            child: SizedBox.expand(),
          )
        : null,
    title: title,
  );
}
