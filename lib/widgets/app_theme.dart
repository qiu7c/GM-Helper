import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

/// 全 App 的配色与尺寸 token，以及组件主题。
///
/// 之前这份文件只有 24 行、只给了一个种子色 —— 没有 `textTheme`、没有
/// `AppBarTheme`，等于**什么都没从主题继承**，于是每个页面都自己手搓
/// `TextStyle(fontSize: 13, fontWeight: FontWeight.bold)` 和 `Colors.grey`。
/// 那是"一眼看出是默认 Flutter"的根子：不是某个页面难看，是根本没有统一的地方。
///
/// 单独抽一份还有个具体原因：「导出图片」那条路**固定用浅色**，不跟着系统深浅
/// 色走 —— 深色 scheme 的前景色是浅的，压在白底上会看不见，而且同学之间传的
/// 课表图白底更好认。两边取同一个实例，导出的图才跟 App 里长的一样。
class AppTheme {
  AppTheme._();

  static const Color seed = Color(0xFF5B8FF9);

  // ---------- 尺寸 token ----------
  //
  // 之前圆角散在 8/10/11/12/14 五个值上，各页面各写各的。收成三档。

  /// 大圆角：悬浮底栏、弹层
  static const double radiusLg = 24;

  /// 中圆角：卡片、输入框、按钮
  static const double radiusMd = 16;

  /// 小圆角：列表里的色块、标签
  static const double radiusSm = 10;

  /// 毛玻璃的模糊半径。**别往上调。**
  ///
  /// Flutter 3.24 没有 `BackdropFilter.grouped` / `BackdropGroup`（3.27 才有），
  /// 所以顶栏和底栏各算各的，两个滤镜 = 每帧两次背景抓取。低端安卓上快速甩动
  /// 有掉帧风险，半径越大越贵。
  static const double glassBlur = 16;

  /// 玻璃底下那层的填充不透明度。
  ///
  /// 太低（<0.6）内容穿过去时字会糊得读不了；太高（>0.85）就看不出是玻璃了，
  /// 跟块纯色板没区别，白掏一次模糊的钱。
  static const double glassFill = 0.78;

  // ---------- 字号标尺 ----------
  //
  // 之前 16 个不同的 fontSize、58 处声明，没有一处读 textTheme。这里定一套
  // 七级标尺，把那些散落的数字收进来。
  //
  // 没有打包字体：App 用的是平台默认（iOS 是 SF、Android 是 Roboto）。换字体
  // 只要把 .ttf 放进 assets/fonts/ 再在 pubspec 里加 fonts:，这份标尺不用动。
  static const TextTheme _text = TextTheme(
    // 课表格子里那几行小字（教室、周次）
    labelSmall: TextStyle(fontSize: 10, height: 1.2),
    // 列表里的次要说明、状态条右侧那句提示
    labelMedium: TextStyle(fontSize: 11, height: 1.25),
    // 正文的次要一行
    bodySmall: TextStyle(fontSize: 12, height: 1.3),
    // 大部分正文
    bodyMedium: TextStyle(fontSize: 13, height: 1.35),
    // 详情弹层、信息行的值
    bodyLarge: TextStyle(fontSize: 15, height: 1.4),
    // 列表标题、按钮文字
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    // 区块标题
    titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
    // 「GMPluse」这种品牌标题
    headlineSmall: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
    // 头像里的那个首字
    displaySmall: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
  );

  static ThemeData light() => _base(Brightness.light);

  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);

    return ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      useMaterial3: true,
      // 部分 TextTheme 交给 ThemeData 去 merge 到 Typography 默认上，
      // 没写的槽位会保住框架默认，不会变成 null
      textTheme: _text,

      appBarTheme: AppBarTheme(
        // 这四个合起来做到"滚动时永不变色"。
        //
        // M3 默认 scrolledUnderElevation: 3，内容滚到顶栏底下时
        // effectiveBackgroundColor 会从 surface 切成 surfaceContainer ——
        // 用户说的"顶栏变色，很别扭"就是它。
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,

        // ⚠ 这几行**必须显式设**，不是可选的润色。
        //
        // `_AppBarDefaultsM3` 不设 systemOverlayStyle，于是回落到
        // `estimateBrightnessForColor(effectiveBackgroundColor)`。上面把背景
        // 设成全透明之后，透明的亮度是 0 → 判定为 dark → 选
        // SystemUiOverlayStyle.light → **浅色模式下状态栏图标变白**，
        // 白图标压在浅色玻璃上，直接看不见。
        systemOverlayStyle:
            isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,

        iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        titleTextStyle: _text.titleLarge?.copyWith(color: scheme.onSurface),
      ),

      cardTheme: CardTheme(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
      ),

      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 0.5,
      ),

      // 换掉底栏之后，方角的贴底 SnackBar 跟圆角悬浮底栏放一起很出戏
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // 只抬最小高度，不动最小宽度 —— 传 Size.fromHeight 会让**每个**
          // FilledButton 都变成整行宽，课表页那个"重试"就毁了
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        // 默认 M3 的 OutlineInputBorder 是 4 的圆角，跟其余部分对不上
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
      ),
    );
  }
}
