import 'package:flutter/material.dart';

import 'pages/timetable_page.dart';

void main() {
  runApp(const ScheduleApp());
}

class ScheduleApp extends StatelessWidget {
  const ScheduleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '广工贸课表',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF5B8FF9),
        useMaterial3: true,
      ),
      home: const TimetablePage(),
    );
  }
}
