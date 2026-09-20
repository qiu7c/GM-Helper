import 'package:flutter/material.dart';

import 'pages/home_shell.dart';
import 'services/course_notes.dart';
import 'services/schedule_prefs.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SchedulePrefs.instance.load();
  await CourseNotes.instance.load();
  runApp(const ScheduleApp());
}

class ScheduleApp extends StatelessWidget {
  const ScheduleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GMPluse',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF5B8FF9),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}
