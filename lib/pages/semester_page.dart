import 'package:flutter/material.dart';

import '../config.dart';
import '../models/course.dart';
import '../services/schedule_prefs.dart';
import '../widgets/course_colors.dart';

/// 全学期总览：把整个学期的课按周平铺出来，一眼看完。
///
/// 课表页是「周视图」，回答不了"这门课上到第几周""哪几周最满"；
/// 这个页面就是干这个的。点某一周会回到课表页并跳到那一周。
///
/// [courses] 要传**未经周次过滤**的整学期课程。
class SemesterPage extends StatelessWidget {
  final List<Course> courses;
  final int totalWeeks;
  final int currentWeek;

  const SemesterPage({
    super.key,
    required this.courses,
    required this.totalWeeks,
    required this.currentWeek,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('全学期总览')),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: totalWeeks,
        itemBuilder: (context, i) => _weekCard(context, i + 1),
      ),
    );
  }

  Widget _weekCard(BuildContext context, int week) {
    final scheme = Theme.of(context).colorScheme;
    final ofWeek =
        courses.where((c) => c.activeInWeek(week)).toList();
    final isCurrent = week == currentWeek;

    final monday = SchedulePrefs.instance.mondayOfWeek(week);
    final sunday = monday.add(const Duration(days: 6));
    final range = '${monday.month}/${monday.day} - '
        '${sunday.month}/${sunday.day}';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: isCurrent ? scheme.primaryContainer : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isCurrent ? scheme.primary : scheme.outlineVariant,
          width: isCurrent ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        // 把周次回传给课表页，由它切过去
        onTap: () => Navigator.of(context).pop(week),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '第 $week 周',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: isCurrent ? scheme.onPrimaryContainer : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    range,
                    style: TextStyle(
                      fontSize: 11,
                      color: isCurrent
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (isCurrent)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('本周',
                          style: TextStyle(
                              fontSize: 10,
                              color: scheme.onPrimary,
                              fontWeight: FontWeight.bold)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (ofWeek.isEmpty)
                Text('本周无课',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant))
              else
                for (var d = 1; d <= 7; d++)
                  ..._dayRow(context, d,
                      ofWeek.where((c) => c.day == d).toList()),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _dayRow(BuildContext context, int day, List<Course> list) {
    if (list.isEmpty) return const [];
    final scheme = Theme.of(context).colorScheme;
    list.sort((a, b) => a.period.compareTo(b.period));
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 34,
              child: Text(
                AppConfig.weekDayNames[day - 1],
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [for (final c in list) _chip(context, c)],
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _chip(BuildContext context, Course c) {
    final color = CourseColors.of(c.name);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.55)),
      ),
      child: Text(
        c.room.isEmpty ? c.name : '${c.name} @${c.room}',
        style: const TextStyle(fontSize: 11, height: 1.2),
      ),
    );
  }
}
