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
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withOpacity(fillOpacity),
            borderRadius: borderRadius,
            border: border,
          ),
          child: child,
        ),
      ),
    );
  }
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
}) {
  final scheme = Theme.of(context).colorScheme;
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
    flexibleSpace: GlassPanel(
      // 直角 + 只有底边，所以这里**不能**传 borderRadius（见 GlassPanel 的注释）
      border: Border(
        bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
      ),
      // 撑满整个矩形。不撑的话 DecoratedBox 没内容就缩成 0 高，玻璃会消失
      child: const SizedBox.expand(),
    ),
    title: title,
  );
}
