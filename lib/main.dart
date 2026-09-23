import 'package:flutter/material.dart';

import 'pages/home_shell.dart';
import 'services/app_info.dart';
import 'services/course_notes.dart';
import 'services/schedule_prefs.dart';
import 'widgets/app_theme.dart';

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
    return MaterialApp(
      title: 'GMPluse',
      debugShowCheckedModeBanner: false,
      // 跟随系统深浅色。
      //
      // 页面里的背景/前景基本都取自 colorScheme，课表格子用的是课程固定色 +
      // 白字（两种模式下对比度都够），所以不需要为深色单独定义配色，
      // 给一份同 seed 的 darkTheme 就够。
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const HomeShell(),
    );
  }
}
