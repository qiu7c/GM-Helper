import 'package:flutter/material.dart';

import '../config.dart';
import '../models/course.dart';
import '../services/schedule_prefs.dart';
import '../widgets/course_colors.dart';
import '../widgets/timetable_grid.dart';

/// 全学期总览：把整个学期的课平铺出来，一眼看完。
///
/// 课表页是「周视图」，回答不了"这门课上到第几周""哪几周最满"；
/// 这个页面就是干这个的。两种看法，右上角那个按钮切换：
///
///  - **按周列表**（默认）：一周一张卡，点某一周会回到课表页并跳到那一周。
///  - **整学期课表**：和首页同一套自绘格子，但铺的是**整学期所有课** ——
///    一个格子里可能叠着好几门课（各自只上其中几周），所以每块都标了周次。
///    这一屏看的是"一周的骨架长什么样"，不用来回翻周。
///
/// [courses] 要传**未经周次过滤**的整学期课程。
class SemesterPage extends StatefulWidget {
  final List<Course> courses;
  final int totalWeeks;
  final int currentWeek;

  /// 决定整学期课表左侧那列显示哪个校区的作息
  final String? campusId;

  const SemesterPage({
    super.key,
    required this.courses,
    required this.totalWeeks,
    required this.currentWeek,
    this.campusId,
  });

  @override
  State<SemesterPage> createState() => _SemesterPageState();
}

class _SemesterPageState extends State<SemesterPage> {
  /// 是否处于「整学期课表」这一面
  bool _grid = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        // 视图切换。放右上角：左边留给返回，别让两个按钮在左边打架
        actions: [
          IconButton(
            // 图标画的是"点了会变成什么"，不是当前状态
            tooltip: _grid ? '切换成按周列表' : '切换成整学期课表',
            icon: Icon(_grid
                ? Icons.view_list_outlined
                : Icons.grid_view_outlined),
            onPressed: () => setState(() => _grid = !_grid),
          ),
        ],
        title: const Text('全学期总览'),
      ),
      body: _grid ? _buildGrid(context) : _buildWeekList(context),
    );
  }

  // ---------- 整学期课表 ----------

  Widget _buildGrid(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Text(
            '整学期所有课。一个格子里可能叠着好几门，下面那行是各自的上课周次；'
            '点一门课看详情。',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: TimetableGrid(
            courses: widget.courses,
            // 整学期视图不显示日期，这个值只是给组件当"本周"的替身，用不上
            week: widget.currentWeek,
            wholeSemester: true,
            campusId: widget.campusId,
            onTap: _showCourse,
            onLongPress: _showCourse,
          ),
        ),
      ],
    );
  }

  /// 格子就那么宽，课程名基本都会被截断，点开看全的
  void _showCourse(Course c) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        // 作息原始串是 "08:00\n09:40"，拿来显示前把换行换成连字符
        final time = AppConfig.periodTime(widget.campusId, c.period)
            .replaceAll('\n', '-');
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: CourseColors.of(c.name),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(c.name,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _detailRow(
                    ctx,
                    Icons.today_outlined,
                    '时间',
                    '${AppConfig.weekDayNames[c.day - 1]} 第 ${c.period} 大节'
                        '${time.isEmpty ? '' : '（$time）'}'),
                _detailRow(
                    ctx,
                    Icons.date_range_outlined,
                    '周次',
                    c.weeks.isEmpty ? '未注明' : '${c.weekRange} 周'),
                _detailRow(ctx, Icons.place_outlined, '教室',
                    c.room.isEmpty ? '未填' : c.room),
                _detailRow(ctx, Icons.person_outline, '教师',
                    c.teacher.isEmpty ? '未填' : c.teacher),
                if (c.sectionRange.isNotEmpty)
                  _detailRow(ctx, Icons.schedule_outlined, '节次', c.sectionRange),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detailRow(
      BuildContext context, IconData icon, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          SizedBox(
            width: 40,
            child: Text(label,
                style:
                    TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  // ---------- 按周列表 ----------

  Widget _buildWeekList(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: widget.totalWeeks,
      itemBuilder: (context, i) => _weekCard(context, i + 1),
    );
  }

  Widget _weekCard(BuildContext context, int week) {
    final scheme = Theme.of(context).colorScheme;
    final ofWeek = widget.courses.where((c) => c.activeInWeek(week)).toList();
    final isCurrent = week == widget.currentWeek;

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
