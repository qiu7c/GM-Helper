import 'package:flutter/material.dart';

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

class ScheduleApp extends StatelessWidget {
  const ScheduleApp({super.key});

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
        // 「底」画在 Navigator **下面**：整棵路由树（含 push 出去的关于页、全学期
        // 总览、更新日志）都浮在这层色斑上。
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
