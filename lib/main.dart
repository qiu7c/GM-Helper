import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pages/home_shell.dart';
import 'services/app_info.dart';
import 'services/course_notes.dart';
import 'services/schedule_prefs.dart';
import 'widgets/app_theme.dart';
import 'widgets/glass_backdrop.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 三件事互不依赖，并行做完再起 UI
  await Future.wait([
    SchedulePrefs.instance.load(),
    CourseNotes.instance.load(),
    AppInfo.load(),
  ]);
  runApp(const ScheduleApp());
}

class ScheduleApp extends StatefulWidget {
  const ScheduleApp({super.key});

  @override
  State<ScheduleApp> createState() => _ScheduleAppState();
}

class _ScheduleAppState extends State<ScheduleApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applySystemUi();
    // 深浅色是用户设置，改了要立刻跟着改系统栏图标颜色
    //（不然浅色栏配白图标 = 看不见）。主题重建由 build 里的
    // ValueListenableBuilder 负责，这里只管系统栏。
    SchedulePrefs.instance.themeMode.addListener(_applySystemUi);
  }

  @override
  void dispose() {
    SchedulePrefs.instance.themeMode.removeListener(_applySystemUi);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 跟随**系统**深浅变化（只在 themeMode == system 时有意义）
  @override
  void didChangePlatformBrightness() => _applySystemUi();

  /// 让内容铺到系统状态栏和导航栏底下（沉浸），并把两条系统栏设成透明。
  ///
  /// 先纠一个容易搞反的点：**内容其实早就铺到栏底下了**。Flutter 的 Android 端
  /// 默认就是 edge-to-edge（`padding.top` 实测约 28 逻辑像素），两处布局也一直按真实
  /// 内边距在走 —— 所以这个改动**不改任何布局**，只改两条系统栏本身：
  ///   * 状态栏原来是**实心系统色**，看着像"内容上面盖了一条"；
  ///   * 导航栏还额外垫着一层默认的**对比度灰底**（见下面那条）。
  ///
  /// 改成透明之后，页面自己的背景/玻璃才会从栏底下透出来，这才叫沉浸。
  /// 布局为什么不用动：
  ///   * **顶部**：`glassAppBar` 返回的是真 `AppBar`（`primary` 默认 true），它自己
  ///     加 `padding.top`；而它的 `flexibleSpace` 本来就铺满"含状态栏区"的整个矩形
  ///     （见 `glass.dart` 里那段注释）—— 玻璃正好延到状态栏底下、标题自动让开。
  ///   * **底部**：`home_shell` 里 `gap = max(30, MediaQuery.padding.bottom)`，底栏
  ///     已经浮在手势条上方了。
  ///
  /// ⚠ `systemNavigationBarContrastEnforced: false` 是这里最要紧的一条：安卓 10+
  /// 默认会给导航栏垫一层**半透明灰底**，那正是"小白条那儿有条灰带"的来源。关掉它，
  /// 手势条才真的浮在 App 自己的背景上。
  void _applySystemUi() {
    final dark = switch (SchedulePrefs.instance.themeMode.value) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => WidgetsBinding
              .instance.platformDispatcher.platformBrightness ==
          Brightness.dark,
    };

    // ⚠ 顺序不能反：`setEnabledSystemUIMode` 会把 overlay style 重置成默认值，
    // 所以样式必须在它**之后**设。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      // 透明而不是画一条自己颜色的栏：要让页面自己的背景/玻璃透上来
      statusBarColor: Colors.transparent,
      // 安卓看 statusBarIconBrightness，iOS 看 statusBarBrightness，两个都得给
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness:
          dark ? Brightness.light : Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    ));
  }

  @override
  Widget build(BuildContext context) {
    // 深浅色是**用户设置**，不写死。监听 prefs 上的 notifier，设置页一改整棵树重配。
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: SchedulePrefs.instance.themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'GMPluse',
        debugShowCheckedModeBanner: false,
        // 页面里的背景/前景基本都取自 colorScheme，课表格子用的是课程固定色 +
        // 白字（两种模式下对比度都够），所以不需要为深色单独定义配色，
        // 给一份同 seed 的 darkTheme 就够。
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: mode,
        // 「底」画在 Navigator **下面**：整棵路由树（含 push 出去的关于页、
        // 更新日志）都浮在这层色斑上。
        //
        // 放在这一处、而不是每个页面各画一遍，是因为页面 Scaffold 现在全是透明的
        // （见 AppTheme.scaffoldBackgroundColor）—— 只要有一个页面漏了底，露出来的
        // 就是窗口底色（安卓上是黑的）。
        builder: (context, child) => Stack(
          // ⚠ expand 不能省：Stack 默认 loose，非 Positioned 的子节点会拿到松约束，
          // Navigator 里的页面会缩成内容高度，整页塌掉
          fit: StackFit.expand,
          children: [
            const GlassBackdrop(),
            if (child != null) child,
          ],
        ),
        home: const HomeShell(),
      ),
    );
  }
}