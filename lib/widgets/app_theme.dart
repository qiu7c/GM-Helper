import 'package:flutter/material.dart';

/// 全 App 的配色种子。
///
/// 单独抽一份是为了「导出图片」那条路：分享出去的图**固定用浅色**，不跟着系统
/// 深浅色走 —— 深色 scheme 里的前景色是浅的，压在白底上会看不见，而且同学之间
/// 传的课表图白底更好认。两边取同一个 seed，导出的图才跟 App 里长的一样。
class AppTheme {
  AppTheme._();

  static const Color seed = Color(0xFF5B8FF9);

  static ThemeData light() => ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.light,
        useMaterial3: true,
      );

  static ThemeData dark() => ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      );
}
