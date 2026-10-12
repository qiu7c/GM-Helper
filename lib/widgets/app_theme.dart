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

  /// 种子色：**中性深灰，不再是淡蓝**。
  ///
  /// 原来是 0xFF5B8FF9（淡蓝），整套色板都带蓝 —— 顶栏标题、图标、"本周"标记、
  /// 今天那一列全是蓝的。现在要的是黑白，种子换成中性色；配合下面
  /// `DynamicSchemeVariant.neutral`，M3 生成的是一套灰阶。
  ///
  /// ⚠ 三个分量**必须完全相等**。之前写的是 0xFF2A2A2C，蓝分量比红绿高 2，
  /// `neutral` 变体依然会把这丝色相留在 primary 上 —— 底栏选中项因此"发蓝"。
  /// 想让整套色板真的没有色相，种子自己就不能带色相。
  static const Color seed = Color(0xFF2E2E2E);

  /// 强调色：淡红。
  ///
  /// **刻意不放进 `ColorScheme`。** 拿它当 primary 会把整套色板都染红，那就不是
  /// 黑白了。强调色只在该"点一下"的地方出现：正在上课、今天那一列 ——
  /// 全 App 上色的地方就这两处，其余一律灰阶。
  static const Color accent = Color(0xFFFF6B6B);

  // ---------- 尺寸 token ----------
  //
  // 之前圆角散在 8/10/11/12/14 五个值上，各页面各写各的。收成三档。

  /// 大圆角：悬浮底栏、弹层
  static const double radiusLg = 24;

  /// 中圆角：卡片、输入框、按钮
  static const double radiusMd = 16;

  /// 小圆角：列表里的色块、标签
  static const double radiusSm = 10;

  /// 毛玻璃的模糊半径。
  ///
  /// ⚠ 这个值**故意开得比原来那条"安全值"大**。原来是 16，注释写着"别往上调"，
  /// 理由是 Flutter 3.24 没有 `BackdropFilter.grouped` / `BackdropGroup`
  /// （3.27 才有），顶栏和底栏各算各的 = 每帧两次背景抓取，半径越大越贵。
  ///
  /// 但 16 配 0.78 的填充**根本看不出是玻璃**。而且关键在于：玻璃是否看得出来，
  /// 主要取决于"背景透过来多少"，不是模糊半径 —— 所以真正起作用的是
  /// [glassFill] 一起降。两个一起调才有玻璃感，只调这个是白花钱。
  ///
  /// 代价如实说：底栏那一块面积小（576×154 物理像素）几乎不花钱；顶栏是整宽，
  /// 低端安卓上快速甩动有掉帧风险。
  ///
  /// ⚠ **已经按这条说明降过一档：30 → 20。** 起因是用户在**实机 iOS**（CI 打的
  /// `flutter build ios --release`，不是 debug 包）上反馈"动画延迟卡顿"。iOS 走
  /// Impeller，整宽的 `BackdropFilter` 每帧都要抓一次背景再糊，半径越大越贵；而按
  /// 上面那段，玻璃感主要由 [glassFill] 决定，半径从 30 降到 20 几乎看不出来，
  /// 所以这是最划算的一刀。**觉得不好看就把 20 改回 30 即可**，只影响观感不影响正确性。
  static const double glassBlur = 20;

  /// 玻璃底下那层的填充不透明度。
  ///
  /// **这个数才是"看不看得出是玻璃"的主开关**，比模糊半径重要得多 —— 它决定背景
  /// 能透过来多少。
  ///
  /// 演变过程：0.78（背景只透两成，模糊开多大都像一块半透明塑料板）→ 0.62（透
  /// 四成）→ **0.34**。到 0.62 时还是"没有沉浸感"，因为实测顶栏和它背后的背景
  /// 亮度几乎一样，两块糊在一起了。
  ///
  /// 0.34 意味着背景透过来约三分之二，模糊才真的看得出来。代价是字要压在更不
  /// 确定的底色上：浅色模式背景范围约 0.66~0.92，深色文字压在最暗处仍有约 5:1
  /// 对比度，够用。再往下调（低于 0.25 左右）字就要开始糊得读不了了。
  static const double glassFill = 0.34;

  /// 盖在 [accent] 上面的字色。
  ///
  /// **不能写白色**：淡红 0xFFFF6B6B 的亮度约 0.33，白字压上去对比度只有
  /// 2.8:1（不够），深字有 7.6:1。今天那一列的表头是实心强调色 + 这个字色。
  static const Color onAccent = Color(0xFF1A1A1E);

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
    // neutral 变体：M3 默认的 tonalSpot 会从种子里抽出一点色相掺进各个槽位，
    // 灰阶就不纯了（表面会带一丝暖调）。neutral 是明确要一套中性色板。
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.neutral,
    );

    return ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      useMaterial3: true,

      // ⚠ 全 App 的 Scaffold 都透明，因为"底"是 `GlassBackdrop` 画的（见 main.dart）。
      // 留一个不透明的底色，顶栏/底栏的玻璃背后就是那块纯色，模糊等于白做。
      //
      // 写在**这一个**地方就够了：所有页面（含 push 出去的关于页、全学期总览、
      // 更新日志）自动跟着走，不用逐页去设 backgroundColor。
      scaffoldBackgroundColor: Colors.transparent,
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

      // 「完全不想要分割线」：分割线一律画不出来。
      //
      // 用"透明"而不是去删页面里每一处 `const Divider()` —— 有几句 Divider 是当
      // **间距**用的（比如分享图那页的 `Divider(height: 20)`），删掉会让布局错位。
      // 保留高度槽位、只让它画不出线，是最不伤布局的做法。
      dividerTheme: const DividerThemeData(color: Colors.transparent),

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
