import 'dart:async';

import 'package:flutter/material.dart';

import '../config.dart';
import '../models/course.dart';
import '../models/period_time.dart';
import '../services/auth_store.dart';
import '../services/auto_login.dart';
import '../services/course_notes.dart';
import '../services/schedule_cache.dart';
import '../services/schedule_prefs.dart';
import '../services/schedule_service.dart';
import '../widgets/course_colors.dart';
import '../widgets/now_status_bar.dart';
import '../widgets/timetable_grid.dart';
import 'semester_page.dart';
import 'share_image_page.dart';

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

  /// 这份缓存是什么时候抓的（只在 _fromCache 时有意义）。
  /// 缓存可能是好几天前的，横幅上得让用户知道，不然会以为是最新的。
  DateTime? _cacheTime;

  /// 有缓存但联网刷新失败了，这里是原因
  String? _staleReason;

  /// 顶部那条「正在上什么课」跟着它走。
  ///
  /// 单开一个 notifier 而不是 setState：格子很重，为了翻一分钟重排整张课表不值当。
  final ValueNotifier<DateTime> _clock = ValueNotifier(DateTime.now());
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _week = SchedulePrefs.instance.currentWeek();
    // 20 秒一次，够让「还有 N 分钟」跟着走，又不会太费
    _ticker = Timer.periodic(const Duration(seconds: 20), (_) {
      _clock.value = DateTime.now();
    });
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
    _ticker?.cancel();
    _clock.dispose();
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
        final at = await ScheduleCache.cachedAt(
            user: user, term: wantTerm, campus: wantCampus);
        if (seq != _loadSeq) return;
        setState(() {
          _result = cached;
          _term = cached.selectedTerm ?? wantTerm;
          _campus = cached.selectedCampus ?? wantCampus;
          _loading = false;
          _error = null;
          _fromCache = true;
          _cacheTime = at;
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
        _cacheTime = null; // 拿到新的了，之前那份缓存的时间戳作废
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

  /// 横幅上那句"显示的是哪份缓存"。取不到时间戳（早期版本写的缓存）就笼统说。
  String _cacheHint() {
    final at = _cacheTime;
    if (at == null) return '显示的是上次缓存的内容';
    return '显示的是缓存（${_ageText(at)}）';
  }

  /// 把时间差说成人话：「刚刚」「3 小时前」「2 天前」「3 个月前」
  String _ageText(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 2) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return '${d.inDays ~/ 30} 个月前';
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

  /// 全学期总览。挑中的那一周由那个页面 pop 回来。
  Future<void> _openSemester() async {
    final w = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => SemesterPage(
          // 注意传的是整学期的课，不是当前这周的 —— 总览自己按周过滤
          courses: _result?.courses ?? const [],
          totalWeeks: _totalWeeks,
          currentWeek: SchedulePrefs.instance.currentWeek(),
        ),
      ),
    );
    if (!mounted || w == null || w == _week) return;
    setState(() => _week = w);
    _load(keepSelection: true);
  }

  /// 导出图片。分享那一步在目标页里做，这里只管把当前这周的课带过去。
  Future<void> _openShareImage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ShareImagePage(
          courses: _visibleCourses,
          week: _week,
          campusId: _campus,
        ),
      ),
    );
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
          IconButton(
            tooltip: '全学期总览',
            icon: const Icon(Icons.grid_view),
            onPressed: _result == null ? null : _openSemester,
          ),
          IconButton(
            tooltip: '导出图片',
            icon: const Icon(Icons.ios_share),
            onPressed: _result == null ? null : _openShareImage,
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
        // 「现在在上什么」只在看本周时才有意义，翻到别的周就撤掉
        if (_week == SchedulePrefs.instance.currentWeek())
          ValueListenableBuilder<DateTime>(
            valueListenable: _clock,
            builder: (_, now, __) => NowStatusBar(
              courses: _visibleCourses,
              now: now,
              campusId: _campus,
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(keepSelection: true),
            child: TimetableGrid(
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
                      : '$_staleReason，${_cacheHint()} · 点此重试',
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
