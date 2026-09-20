import 'package:flutter/material.dart';

import '../config.dart';
import '../models/course.dart';
import '../services/auth_store.dart';
import '../services/schedule_service.dart';
import '../widgets/course_colors.dart';
import 'login_page.dart';

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
  int _week = 1; // 当前查看的周次
  bool _showAllWeeks = false; // true=显示全部周(不按周过滤)

  @override
  void initState() {
    super.initState();
    _week = _calcCurrentWeek();
    _load();
  }

  int _calcCurrentWeek() {
    final diff = DateTime.now().difference(AppConfig.termFirstMonday).inDays;
    if (diff < 0) return 1;
    return diff ~/ 7 + 1;
  }

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
      final result = await service.fetch(
        term: keepSelection ? _term : (_term ?? await AuthStore.getLastTerm()),
        week: _showAllWeeks ? '' : _week.toString(),
        campus:
            keepSelection ? _campus : (_campus ?? await AuthStore.getLastCampus()),
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
      MaterialPageRoute(builder: (_) => const LoginPage()),
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

  Future<void> _logout() async {
    await AuthStore.clear();
    _goLogin();
  }

  /// 当前显示的课程（按周过滤）
  List<Course> get _visibleCourses {
    final all = _result?.courses ?? [];
    if (_showAllWeeks) return all;
    return all.where((c) => c.activeInWeek(_week)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_showAllWeeks ? '课表（全部周）' : '课表 · 第$_week周'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _load(keepSelection: true),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'logout') _logout();
              if (v == 'week') _pickWeek();
              if (v == 'term') _pickTerm();
              if (v == 'campus') _pickCampus();
              if (v == 'all') {
                setState(() => _showAllWeeks = !_showAllWeeks);
                _load(keepSelection: true);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'week', child: Text('选择周次')),
              const PopupMenuItem(value: 'term', child: Text('选择学期')),
              const PopupMenuItem(value: 'campus', child: Text('选择校区')),
              PopupMenuItem(
                  value: 'all',
                  child: Text(_showAllWeeks ? '按周显示' : '显示全部周')),
              const PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: _showAllWeeks ? null : _weekBar(),
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
        onTap: _showCourseDetail,
      ),
    );
  }

  Widget _weekBar() {
    final weeks = List.generate(30, (i) => i + 1);
    return SafeArea(
      child: SizedBox(
        height: 56,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: weeks.length,
          itemBuilder: (_, i) {
            final w = weeks[i];
            final selected = w == _week;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: ChoiceChip(
                label: Text('第$w周'),
                selected: selected,
                onSelected: (_) {
                  setState(() => _week = w);
                  _load(keepSelection: true);
                },
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _pickWeek() async {
    final w = await showModalBottomSheet<int>(
      context: context,
      builder: (_) => ListView(
        children: List.generate(
          30,
          (i) => ListTile(
            title: Text('第${i + 1}周'),
            selected: (i + 1) == _week,
            onTap: () => Navigator.pop(context, i + 1),
          ),
        ),
      ),
    );
    if (w != null) {
      setState(() => _week = w);
      _load(keepSelection: true);
    }
  }

  Future<void> _pickTerm() async {
    final terms = _result?.terms ?? [];
    if (terms.isEmpty) return;
    final v = await _pickOption('选择学期', terms, _term);
    if (v != null) {
      setState(() => _term = v);
      _load(keepSelection: true);
    }
  }

  Future<void> _pickCampus() async {
    final campuses = _result?.campuses ?? [];
    if (campuses.isEmpty) return;
    final v = await _pickOption('选择校区', campuses, _campus);
    if (v != null) {
      setState(() => _campus = v);
      _load(keepSelection: true);
    }
  }

  Future<String?> _pickOption(
      String title, List<SelectOption> opts, String? current) {
    return showModalBottomSheet<String>(
      context: context,
      builder: (_) => ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(title,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          ...opts.map((o) => ListTile(
                title: Text(o.label),
                selected: o.value == current,
                onTap: () => Navigator.pop(context, o.value),
              )),
        ],
      ),
    );
  }

  void _showCourseDetail(Course c) {
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(c.name,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
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
          Text('$label：',
              style: const TextStyle(color: Colors.grey)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

/// 课表网格：左侧节次列 + 顶部星期行 + 课程卡片
class _TimetableGrid extends StatelessWidget {
  final List<Course> courses;
  final void Function(Course) onTap;

  const _TimetableGrid({required this.courses, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // 用 map[period][day] 取课程
    Course? at(int period, int day) {
      for (final c in courses) {
        if (c.period == period && c.day == day) return c;
      }
      return null;
    }

    const timeColWidth = 44.0;
    final today = DateTime.now().weekday; // 1..7

    return LayoutBuilder(builder: (context, constraints) {
      final dayWidth =
          (constraints.maxWidth - timeColWidth) / 7;
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          children: [
            // 顶部星期行
            Row(
              children: [
                const SizedBox(width: timeColWidth, height: 40),
                for (var d = 1; d <= 7; d++)
                  Container(
                    width: dayWidth,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: d == today
                          ? Theme.of(context).colorScheme.primaryContainer
                          : null,
                    ),
                    child: Text(
                      AppConfig.weekDayNames[d - 1],
                      style: TextStyle(
                        fontWeight:
                            d == today ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
              ],
            ),
            // 每个大节一行
            for (var p = 1; p <= AppConfig.periodCount; p++)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 左侧节次
                    SizedBox(
                      width: timeColWidth,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('${p}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(
                            AppConfig.periodTimes[p - 1],
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 9, color: Colors.grey, height: 1.2),
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
          ],
        ),
      );
    });
  }

  Widget _cell(BuildContext context, Course? c) {
    if (c == null) {
      return Container(
        margin: const EdgeInsets.all(1.5),
        constraints: const BoxConstraints(minHeight: 90),
      );
    }
    final color = CourseColors.of(c.name);
    return Padding(
      padding: const EdgeInsets.all(1.5),
      child: InkWell(
        onTap: () => onTap(c),
        child: Container(
          constraints: const BoxConstraints(minHeight: 90),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(6),
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
                    height: 1.15),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              if (c.room.isNotEmpty)
                Text(
                  '@${c.room}',
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              if (c.teacher.isNotEmpty)
                Text(
                  c.teacher,
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
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
