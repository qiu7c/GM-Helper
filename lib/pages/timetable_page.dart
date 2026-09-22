import 'package:flutter/material.dart';

import '../config.dart';
import '../models/course.dart';
import '../services/auth_store.dart';
import '../services/auto_login.dart';
import '../services/course_notes.dart';
import '../services/schedule_cache.dart';
import '../services/schedule_prefs.dart';
import '../services/schedule_service.dart';
import '../widgets/course_colors.dart';

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

  /// 登录页是否已经打开，避免重复弹（登录状态变化可能同时触发多条路径）
  bool _loginOpen = false;

  /// 加载轮次：并发/重入时只认最新那次的结果，避免旧响应把新数据盖回去
  int _loadSeq = 0;

  /// 当前显示的是不是缓存内容（还没刷新成功）
  bool _fromCache = false;

  /// 有缓存但联网刷新失败了，这里是原因
  String? _staleReason;

  @override
  void initState() {
    super.initState();
    _week = SchedulePrefs.instance.currentWeek();
    // 「我的」页改学期/校区后，自动重载
    SchedulePrefs.instance.revision.addListener(_onPrefsChanged);
    // 在「我的」页登录/退出后，课表也跟着刷新
    AuthStore.authRevision.addListener(_onAuthChanged);
    // 备注改动后重绘角标
    CourseNotes.instance.revision.addListener(_onNotesChanged);
    _load();
  }

  @override
  void dispose() {
    SchedulePrefs.instance.revision.removeListener(_onPrefsChanged);
    AuthStore.authRevision.removeListener(_onAuthChanged);
    CourseNotes.instance.revision.removeListener(_onNotesChanged);
    super.dispose();
  }

  void _onNotesChanged() {
    if (mounted) setState(() {});
  }

  /// 登录状态变了：登录成功就重载课表。
  ///
  /// 只在"已登录"时重载，退出/失效不在这里处理 —— 那两条路走 _load 自己的
  /// sessionExpired 分支，否则会和 _goLogin 抢着弹登录页。
  void _onAuthChanged() {
    AuthStore.isLoggedIn().then((ok) {
      if (ok && mounted) _load(keepSelection: true);
    });
  }

  void _onPrefsChanged() {
    _term = SchedulePrefs.instance.term;
    _campus = SchedulePrefs.instance.campus;
    _load(keepSelection: true);
  }

  int get _totalWeeks => SchedulePrefs.instance.totalWeeks;

  /// 加载课表：**先铺缓存，再联网刷新**。
  ///
  /// 教务系统一次返回整个学期的课表，周次是本地过滤的，所以缓存按
  /// 「学期+校区」存一份就够，切周次也走同一条路 —— 于是切周次不会再白屏
  /// 一下，打开 App 也是立刻有内容。
  Future<void> _load({bool keepSelection = false}) async {
    final seq = ++_loadSeq;

    final cookie = await AuthStore.getCookie();
    if (seq != _loadSeq) return; // 已有更新的一次加载在跑
    if (cookie == null || cookie.isEmpty) {
      _goLogin();
      return;
    }
    // 缓存的 key 里带账号：会话过期时缓存不清，带上账号才不会串到别人身上
    final user = await AuthStore.getSavedUsername();
    if (seq != _loadSeq) return;

    // 先把这次要查的学期/校区定下来：缓存和网络请求用同一套参数，
    // 否则缓存铺的是 A 学期、网络回的是 B 学期，会闪。
    final wantTerm =
        keepSelection ? _term : (_term ?? await AuthStore.getLastTerm());
    final wantCampus =
        keepSelection ? _campus : (_campus ?? await AuthStore.getLastCampus());
    if (seq != _loadSeq) return;

    // 1) 铺缓存。已经显示了同一份内容就不重复读了。
    final changed = wantTerm != _term || wantCampus != _campus;
    if (_result == null || changed) {
      final cached =
          await ScheduleCache.read(user: user, term: wantTerm, campus: wantCampus);
      if (seq != _loadSeq) return;
      if (cached != null) {
        setState(() {
          _result = cached;
          _term = cached.selectedTerm ?? wantTerm;
          _campus = cached.selectedCampus ?? wantCampus;
          _loading = false;
          _error = null;
          _fromCache = true;
          _staleReason = null; // 刷新还在路上，先显示"正在更新"
        });
      }
    }
    if (seq != _loadSeq) return;
    // 有东西可看就不转圈，让内容留在屏幕上等刷新
    if (_result == null && !_loading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    // 2) 联网刷新
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
        term: wantTerm,
        week: _week.toString(),
        campus: wantCampus,
      );
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _result = result;
        _term = result.selectedTerm ?? _term;
        _campus = result.selectedCampus ?? _campus;
        _loading = false;
        _error = null;
        _fromCache = false;
        _staleReason = null;
      });
      await ScheduleCache.write(
          user: user, term: _term, campus: _campus, result: result);
      if (_term != null) await AuthStore.saveLastTerm(_term!);
      if (_campus != null) await AuthStore.saveLastCampus(_campus!);
      SchedulePrefs.instance.sync(term: _term, campus: _campus);
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      if (e == ScheduleService.sessionExpired) {
        // 先让出这一轮，再弹登录页：否则登录成功后的那次 _load 会被
        // 自己这轮的 seq 挡掉
        _loadSeq++;
        // 只清 Cookie，课表缓存留着：会话过期不代表那学期的课表变了，
        // 用户在看到登录页之前至少还有课表可看（见 AuthStore.clearSession）。
        //
        // 带上这张失败的票去清：如果「我的」页那边（同一个 IndexedStack，
        // 启动时同时发请求）已经先一步自动重登、换上了新票，这里就什么都
        // 不该清 —— 否则会把刚存进来的新票删掉，用户被无谓地踢去手动登录。
        final cleared = await AuthStore.clearSession(failedCookie: cookie);
        // 这里不能再比 seq：上面刚 _loadSeq++ 过，等于必然不等。
        // 真正要防的只是"清的过程中页面被销毁"。
        if (!mounted) return;
        if (!cleared) {
          // 票已经换新了，这次失效是过期的旧消息：拿新票重来一次就好
          _load(keepSelection: true);
          return;
        }
        _goLogin();
        return;
      }
      setState(() {
        _loading = false;
        if (_result != null) {
          // 缓存还能看，别整屏报错把人吓一跳，顶部挂一行提示就够
          _fromCache = true;
          _staleReason = _whyOffline(e);
        } else {
          _error = '加载失败：$e';
        }
      });
    }
  }

  /// 把网络异常压成一句人话，挂在缓存提示后面
  String _whyOffline(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('Connection')) {
      return '网络不可用';
    }
    if (s.contains('imeout')) return '请求超时';
    return '刷新失败';
  }

  Future<void> _goLogin() async {
    if (!mounted || _loginOpen) return;
    _loginOpen = true;
    try {
      // 勾了「自动登录」就先悄悄登一次，不行再打登录页
      final ok = await AutoLogin.ensureLoggedIn(context);
      if (!mounted) return;
      if (ok) {
        // 登录成功：saveCookie 已经通知过 _onAuthChanged，那次 _load 正在跑；
        // 这里再叫一次是保底（seq 机制保证不会互相覆盖）。用默认的
        // keepSelection=false，按登录后的实际情况重新解析学期/校区。
        _load();
      } else {
        setState(() {
          _loading = false;
          _error = '未登录';
        });
      }
    } finally {
      _loginOpen = false;
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
    return Column(
      children: [
        if (_fromCache) _staleBanner(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(keepSelection: true),
            child: _TimetableGrid(
              courses: _visibleCourses,
              week: _week,
              onTap: _showCourseDetail,
              onLongPress: _editNote,
              campusId: _campus,
            ),
          ),
        ),
      ],
    );
  }

  /// 显示的是缓存内容时顶上挂的一条：点一下立刻重试
  Widget _staleBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => _load(keepSelection: true),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(_staleReason == null ? Icons.sync : Icons.cloud_off,
                  size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _staleReason == null
                      ? '正在更新课表…'
                      : '$_staleReason，显示的是上次缓存的内容 · 点此重试',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 长按课程：编辑长期备注（按课程名保存，跨周次生效）
  Future<void> _editNote(Course c) async {
    final ctrl = TextEditingController(
        text: CourseNotes.instance.noteOf(c.name) ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Row(
          children: [
            Container(
              width: 6,
              height: 20,
              decoration: BoxDecoration(
                color: CourseColors.of(c.name),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(c.name,
                  style: const TextStyle(fontSize: 16),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          maxLength: 100,
          decoration: const InputDecoration(
            hintText: '给这门课加个备注，比如「带课本」「机房上课」',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          if (CourseNotes.instance.hasNote(c.name))
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, '__delete__'),
              child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null) return; // 取消
    if (result == '__delete__') {
      await CourseNotes.instance.clearNote(c.name);
    } else {
      await CourseNotes.instance.setNote(c.name, result);
    }
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
                IconButton(
                  tooltip: '备注',
                  icon: Icon(
                    CourseNotes.instance.hasNote(c.name)
                        ? Icons.edit_note
                        : Icons.note_add_outlined,
                    color: Colors.grey,
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    _editNote(c);
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (CourseNotes.instance.noteOf(c.name) != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: CourseColors.of(c.name).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.push_pin, size: 16, color: CourseColors.of(c.name)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(CourseNotes.instance.noteOf(c.name)!)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ] else
              const SizedBox(height: 8),
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
  final void Function(Course) onLongPress;
  final String? campusId;

  const _TimetableGrid({
    required this.courses,
    required this.week,
    required this.onTap,
    required this.onLongPress,
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
