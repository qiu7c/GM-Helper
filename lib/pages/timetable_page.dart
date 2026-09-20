import 'package:flutter/material.dart';

import '../config.dart';
import '../models/course.dart';
import '../services/auth_store.dart';
import '../services/schedule_prefs.dart';
import '../services/schedule_service.dart';
import '../widgets/course_colors.dart';
import 'password_login_page.dart';

class TimetablePage extends StatefulWidget {
  const TimetablePage({super.key});

  @override
  State<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends State<TimetablePage> {
  bool _loading = true;
  String? _error;
  ScheduleResult? _result;

  String? _term;
  String? _campus;
  int _week = 1;
  bool _calendarLoaded = false; // 本会话是否已同步过教务日历

  @override
  void initState() {
    super.initState();
    _week = SchedulePrefs.instance.currentWeek();
    // 「我的」页改学期/校区后，自动重载
    SchedulePrefs.instance.revision.addListener(_onPrefsChanged);
    _load();
  }

  @override
  void dispose() {
    SchedulePrefs.instance.revision.removeListener(_onPrefsChanged);
    super.dispose();
  }

  void _onPrefsChanged() {
    _term = SchedulePrefs.instance.term;
    _campus = SchedulePrefs.instance.campus;
    _load(keepSelection: true);
  }

  int get _totalWeeks => SchedulePrefs.instance.totalWeeks;

  Future<void> _load({bool keepSelection = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final cookie = await AuthStore.getCookie();
    if (cookie == null || cookie.isEmpty) {
      _goLogin();
      return;
    }

    try {
      final service = ScheduleService(cookie);

      // 首次加载：向教务同步真实的当前周/总周数/日期
      if (!_calendarLoaded) {
        final cal = await service.fetchCalendar();
        if (cal != null) {
          await SchedulePrefs.instance.applyCalendar(cal);
          _calendarLoaded = true;
          if (!keepSelection) _week = cal.currentWeek;
        }
      }

      final result = await service.fetch(
        term: keepSelection ? _term : (_term ?? await AuthStore.getLastTerm()),
        week: _week.toString(),
        campus: keepSelection
            ? _campus
            : (_campus ?? await AuthStore.getLastCampus()),
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _term = result.selectedTerm ?? _term;
        _campus = result.selectedCampus ?? _campus;
        _loading = false;
      });
      if (_term != null) await AuthStore.saveLastTerm(_term!);
      if (_campus != null) await AuthStore.saveLastCampus(_campus!);
      SchedulePrefs.instance.sync(term: _term, campus: _campus);
    } catch (e) {
      if (!mounted) return;
      if (e == ScheduleService.sessionExpired) {
        await AuthStore.clear();
        _goLogin();
        return;
      }
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _goLogin() async {
    if (!mounted) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const PasswordLoginPage()),
    );
    if (ok == true) {
      _load();
    } else {
      setState(() {
        _loading = false;
        _error = '未登录';
      });
    }
  }

  List<Course> get _visibleCourses {
    final all = _result?.courses ?? [];
    return all.where((c) => c.activeInWeek(_week)).toList();
  }

  void _prevWeek() {
    if (_week <= 1) return;
    setState(() => _week--);
    _load(keepSelection: true);
  }

  void _nextWeek() {
    if (_week >= _totalWeeks) return;
    setState(() => _week++);
    _load(keepSelection: true);
  }

  /// 按日期挑周：选任意一天，跳到它所在的教学周
  Future<void> _pickDate() async {
    final first = SchedulePrefs.instance.firstMonday;
    final last = SchedulePrefs.instance
        .mondayOfWeek(_totalWeeks)
        .add(const Duration(days: 6));
    final now = DateTime.now();
    final initial = SchedulePrefs.instance.mondayOfWeek(_week);
    final d = await showDatePicker(
      context: context,
      initialDate: (now.isAfter(first) && now.isBefore(last)) ? now : initial,
      firstDate: first,
      lastDate: last,
      helpText: '选择日期跳转到对应教学周',
    );
    if (d != null) {
      final w = SchedulePrefs.instance.weekOfDate(d);
      setState(() => _week = w);
      _load(keepSelection: true);
    }
  }

  Future<void> _pickWeek() async {
    final w = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (_) => GridView.count(
        crossAxisCount: 5,
        padding: const EdgeInsets.all(16),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        children: List.generate(_totalWeeks, (i) {
          final w = i + 1;
          final sel = w == _week;
          return InkWell(
            onTap: () => Navigator.pop(context, w),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: sel
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('$w',
                  style: TextStyle(
                    color: sel ? Colors.white : null,
                    fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                  )),
            ),
          );
        }),
      ),
    );
    if (w != null) {
      setState(() => _week = w);
      _load(keepSelection: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        titleSpacing: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              iconSize: 20,
              icon: const Icon(Icons.chevron_left),
              onPressed: _week > 1 ? _prevWeek : null,
            ),
            InkWell(
              onTap: _pickWeek,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text('第 $_week 周',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold)),
              ),
            ),
            IconButton(
              iconSize: 20,
              icon: const Icon(Icons.chevron_right),
              onPressed: _week < _totalWeeks ? _nextWeek : null,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '按日期跳转',
            icon: const Icon(Icons.event),
            onPressed: _pickDate,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => _load(keepSelection: true),
              child: const Text('重试'),
            ),
            TextButton(onPressed: _goLogin, child: const Text('重新登录')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(keepSelection: true),
      child: _TimetableGrid(
        courses: _visibleCourses,
        week: _week,
        onTap: _showCourseDetail,
        campusId: _campus,
      ),
    );
  }

  void _showCourseDetail(Course c) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 6,
                  height: 24,
                  decoration: BoxDecoration(
                    color: CourseColors.of(c.name),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(c.name,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _detailRow(Icons.person, '教师', c.teacher),
            _detailRow(Icons.room, '教室', c.room),
            _detailRow(Icons.group, '教学班', c.teachingClass),
            _detailRow(Icons.calendar_today, '周次节次', c.rawWeeks),
            _detailRow(Icons.access_time, '时间',
                '${AppConfig.weekDayNames[c.day - 1]} ${AppConfig.periodNames[c.period - 1]}'),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.grey),
          const SizedBox(width: 10),
          Text('$label：', style: const TextStyle(color: Colors.grey)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

/// 课表网格：左侧节次列 + 顶部星期(带日期)行 + 课程卡片
class _TimetableGrid extends StatelessWidget {
  final List<Course> courses;
  final int week;
  final void Function(Course) onTap;
  final String? campusId;

  const _TimetableGrid({
    required this.courses,
    required this.week,
    required this.onTap,
    this.campusId,
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
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          children: [
            // 顶部星期 + 日期
            Row(
              children: [
                SizedBox(width: timeColWidth, height: 52),
                for (var d = 1; d <= 7; d++)
                  _dayHeader(context, d, monday, isCurrentWeek && d == today,
                      dayWidth),
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
                                fontSize: 8.5,
                                color: Colors.grey,
                                height: 1.2),
                          ),
                        ],
                      ),
                    ),
                    for (var d = 1; d <= 7; d++)
                      SizedBox(
                        width: dayWidth,
                        child: _cell(context, at(p, d)),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
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
    return Padding(
      padding: EdgeInsets.only(bottom: multi ? 3 : 0),
      child: InkWell(
        onTap: () => onTap(c),
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
          child: Column(
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
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
