import 'package:flutter/material.dart';

import '../config.dart';
import '../models/course.dart';
import '../services/course_notes.dart';
import '../services/schedule_prefs.dart';
import 'course_colors.dart';

/// 一周的课表网格：左侧大节时间列 + 7 天。
///
/// 从 timetable_page 里抽出来的，导出图片那条路也要用同一套格子 ——
/// 分享出去的图和 App 里看到的必须是同一个样子，不能两处各画一份。
class TimetableGrid extends StatelessWidget {
  final List<Course> courses;
  final int week;
  final void Function(Course) onTap;
  final void Function(Course) onLongPress;

  /// 用哪个校区的作息时间（决定左侧那列显示几点几分）
  final String? campusId;

  /// 嵌进别人的滚动视图里时置 true：自己不再套一层滚动，交给外面滚。
  /// 导出图片那条路要把整块内容一次性摆进画布，套滚动视图反而量不出高度。
  final bool embedded;

  const TimetableGrid({
    super.key,
    required this.courses,
    required this.week,
    required this.onTap,
    required this.onLongPress,
    this.campusId,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context) {
    List<Course> at(int period, int day) => courses
        .where((c) => c.period == period && c.day == day)
        .toList();

    const timeColWidth = 38.0;
    final today = DateTime.now().weekday;
    // 本周周一日期
    final monday = SchedulePrefs.instance.mondayOfWeek(week);
    final isCurrentWeek = SchedulePrefs.instance.currentWeek() == week;

    return LayoutBuilder(builder: (context, constraints) {
      final dayWidth = (constraints.maxWidth - timeColWidth) / 7;
      // 两种用法下高度都是不限的（外面要么是滚动视图，要么是 FittedBox 里的
      // 固定宽画布），所以每行的高度交给 IntrinsicHeight 自己算。
      final grid = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部星期 + 日期
          Row(
            children: [
              SizedBox(width: timeColWidth, height: 52),
              for (var d = 1; d <= 7; d++)
                _dayHeader(
                    context, d, monday, isCurrentWeek && d == today, dayWidth),
            ],
          ),
          for (var p = 1; p <= AppConfig.periodCount; p++)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: timeColWidth,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('$p',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 2),
                        Text(
                          AppConfig.periodTime(campusId, p),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 8.5, color: Colors.grey, height: 1.2),
                        ),
                      ],
                    ),
                  ),
                  for (var d = 1; d <= 7; d++)
                    SizedBox(width: dayWidth, child: _cell(context, at(p, d))),
                ],
              ),
            ),
          const SizedBox(height: 16),
        ],
      );

      if (embedded) return grid;
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: grid,
      );
    });
  }

  Widget _dayHeader(BuildContext context, int day, DateTime monday,
      bool isToday, double width) {
    final date = monday.add(Duration(days: day - 1));
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: 52,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isToday ? scheme.primaryContainer : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            AppConfig.weekDayNames[day - 1],
            style: TextStyle(
              fontSize: 13,
              fontWeight: isToday ? FontWeight.bold : FontWeight.w500,
              color: isToday ? scheme.onPrimaryContainer : null,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${date.month}/${date.day}',
            style: TextStyle(
              fontSize: 10,
              color: isToday ? scheme.onPrimaryContainer : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, List<Course> list) {
    if (list.isEmpty) {
      return Container(
        margin: const EdgeInsets.all(2),
        constraints: const BoxConstraints(minHeight: 92),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in list)
            Expanded(child: _courseBox(c, multi: list.length > 1)),
        ],
      ),
    );
  }

  Widget _courseBox(Course c, {required bool multi}) {
    final color = CourseColors.of(c.name);
    final note = CourseNotes.instance.noteOf(c.name);
    return Padding(
      padding: EdgeInsets.only(bottom: multi ? 3 : 0),
      child: InkWell(
        onTap: () => onTap(c),
        onLongPress: () => onLongPress(c),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: BoxConstraints(minHeight: multi ? 44 : 92),
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: color.withOpacity(0.9),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.25),
                blurRadius: 3,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        height: 1.2),
                    maxLines: multi ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  if (c.room.isNotEmpty)
                    Text(
                      '@${c.room}',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (c.teacher.isNotEmpty && !multi)
                    Text(
                      c.teacher,
                      style: const TextStyle(color: Colors.white70, fontSize: 10),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (note != null && !multi) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.push_pin, size: 9, color: Colors.white),
                        const SizedBox(width: 2),
                        Expanded(
                          child: Text(
                            note,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 9, height: 1.1),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
              // 多课叠放时空间小，仅用右上角图钉标记有备注
              if (note != null && multi)
                const Positioned(
                  top: 0,
                  right: 0,
                  child: Icon(Icons.push_pin, size: 10, color: Colors.white),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
