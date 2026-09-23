import 'dart:async';

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
import '../widgets/glass.dart';
import '../widgets/now_status_bar.dart';
import '../widgets/skeleton.dart';
import '../widgets/timetable_grid.dart';
import 'semester_page.dart';
import 'share_image_page.dart';

/// 顶栏「⋮」里收着的功能。
///
/// 按日期跳转**不在此列**：那个是高频操作，留在外面当图标。
enum _More { semester, shareImage }

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

  /// 正在静默重登（也就是 _goLogin 里那段时间）。
  ///
  /// 静默登录那一层是 opacity:0 的，屏幕上一点变化都没有。横幅要是还写着
  /// 「正在更新课表…」就是纯骗人 —— 这会儿根本没在更新课表，是在走一遍完整的
  /// CAS 登录。这条状态就是让横幅能说实话。
  bool _loggingIn = false;

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
  ///
  /// 这条现在**还要驱动顶栏高度** —— 状态卡搬进了 `AppBar.bottom`，而 AppBar
  /// 是在自己 build 的时候就把高度定死的，光让状态卡重建不够。所以下面 build()
  /// 用它在整页外面包了一层。格子是纯 Stateless，重建只是把同一批 widget 描述
  /// 重新 diff 一遍，不重新请求数据，20 秒一次可以接受。
  final ValueNotifier<DateTime> _clock = ValueNotifier(DateTime.now());
  Timer? _ticker;

  /// `_staleBanner` 的高度，写死。
  ///
  /// 它也在 `AppBar.bottom` 里，所以高度必须是个常量：8+8 的上下内边距，加
  /// 16 的内容（转圈和图标都是 16，文字比它矮）。
  static const double _bannerHeight = 32;

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
    // 让横幅改成"正在自动登录"。这段时间可能十几秒，而且屏幕上看不到任何东西，
    // 不说清楚用户只会以为卡死了。
    setState(() => _loggingIn = true);
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
      // 走到这儿要么登录成了（接下来真是在更新课表），要么已经失败——
      // 两种情况下"正在自动登录"都不再成立，横幅该换个说法了。
      if (mounted) setState(() => _loggingIn = false);
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
                    // 选中的那个压在实心主色上，得用 onPrimary
                    color: sel
                        ? Theme.of(context).colorScheme.onPrimary
                        : null,
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
          // 整学期课表那面要按校区画左侧的节次时间
          campusId: _campus,
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

  /// 顶栏两侧图标按钮的宽度。左右都用它，中间那段才稳得住。
  static const double _barButtonWidth = 40;

  void _goWeek(int w) {
    if (w == _week || w < 1 || w > _totalWeeks) return;
    setState(() => _week = w);
    _load(keepSelection: true);
  }

  /// 顶栏图标按钮：压到 40 宽（比默认的 48 窄），好给中间的周切换器让出地方
  Widget _barButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 20,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(
          width: _barButtonWidth, height: kMinInteractiveDimension),
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }

  /// 周切换器：‹ 第 N 周 ›。宽度全由内容决定，外面用两个等宽的 Expanded 夹住它。
  Widget _weekSwitcher() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _chevron(Icons.chevron_left, _week > 1 ? _prevWeek : null),
        InkWell(
          onTap: _pickWeek,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text('第 $_week 周',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
        _chevron(Icons.chevron_right, _week < _totalWeeks ? _nextWeek : null),
      ],
    );
  }

  Widget _chevron(IconData icon, VoidCallback? onPressed) {
    return IconButton(
      iconSize: 20,
      padding: EdgeInsets.zero,
      constraints:
          const BoxConstraints.tightFor(width: 32, height: kMinInteractiveDimension),
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }

  PopupMenuItem<_More> _menuItem(_More value, IconData icon, String label) {
    return PopupMenuItem<_More>(
      value: value,
      // 还没有课表可看时这两项都没意义
      enabled: _result != null,
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 整页跟着 20 秒的时钟走。原因见 `_clock` 的注释：状态卡搬进 AppBar.bottom
    // 之后，顶栏的高度成了内容的一部分，而 AppBar 只在它自己 build 时才重新量
    // —— 只让状态卡重建的话，课间那一刻档位从「上课中」跳到「下一节」，文字已经
    // 换了、顶栏还是旧高度，中间会裂出一条缝。
    return ValueListenableBuilder<DateTime>(
      valueListenable: _clock,
      builder: (context, now, _) => _scaffold(context, now),
    );
  }

  Widget _scaffold(BuildContext context, DateTime now) {
    final curWeek = SchedulePrefs.instance.currentWeek();
    return Scaffold(
      // 内容从玻璃顶栏**底下**穿过去。不然视口从顶栏下沿开始，玻璃背后是一块
      // 纯色，模糊等于白做 —— 玻璃得背后有东西才看得出是玻璃。
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        context: context,
        // 刻意不用 leading/actions：那套是按各自宽度去抢地盘、再把 title 挤到
        // 剩下的空间里居中，右边图标一多就偏了。这里让 title 铺满整条，内部
        // 用两个**等宽**的 Expanded 夹住周切换器 —— 于是不管右边收进去几个
        // 功能，中间那一段始终落在屏幕正中。
        //
        // 这也是 glassAppBar 不能给这个页面传 leading/actions 的原因。
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        title: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _barButton(
                  icon: Icons.today_outlined,
                  tooltip: '回到本周',
                  // 已在本周就置灰：既是"你现在就在本周"的提示，也保证两侧
                  // 宽度不随状态变化（一变中间就跟着偏）
                  onPressed: _week == curWeek ? null : () => _goWeek(curWeek),
                ),
              ),
            ),
            _weekSwitcher(),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _barButton(
                      icon: Icons.event_outlined,
                      tooltip: '按日期跳转',
                      onPressed: _pickDate,
                    ),
                    PopupMenuButton<_More>(
                      tooltip: '更多',
                      padding: EdgeInsets.zero,
                      onSelected: (v) {
                        if (v == _More.semester) {
                          _openSemester();
                        } else {
                          _openShareImage();
                        }
                      },
                      itemBuilder: (context) => [
                        _menuItem(
                            _More.semester, Icons.grid_view_outlined, '全学期总览'),
                        _menuItem(_More.shareImage, Icons.ios_share, '导出图片'),
                      ],
                      // 用 child 而不是 icon：这样宽度由我们说了算，
                      // 好跟左边那个按钮对齐（PopupMenuButton 默认跟着
                      // IconButton 走，最小 48）
                      child: const SizedBox(
                        width: _barButtonWidth,
                        height: kMinInteractiveDimension,
                        child: Icon(Icons.more_vert, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        bottom: _headerBottom(now),
      ),
      body: _buildBody(),
    );
  }

  /// 顶栏底下那一块：缓存横幅 + 「现在在上什么」，两者都钉在玻璃上。
  ///
  /// 高度得自己报 —— `glassAppBar` 的 `flexibleSpace` 会盖住整个 AppBar 矩形
  /// （含 `bottom`），所以这块的底色也是玻璃，课表从它下面穿过去。
  PreferredSizeWidget _headerBottom(DateTime now) {
    // 「现在在上什么」只在看本周时才有意义，翻到别的周就撤掉
    final status = _week == SchedulePrefs.instance.currentWeek()
        ? NowStatusBar(
            courses: _visibleCourses,
            now: now,
            campusId: _campus,
          )
        : null;

    // 高度直接问状态卡要 —— 它自己算的，跟它渲染出来的那个 SizedBox 是同一套
    // 逻辑，不会两边算出两个数
    final height =
        (_fromCache ? _bannerHeight : 0.0) + (status?.preferredSize.height ?? 0.0);

    return PreferredSize(
      preferredSize: Size.fromHeight(height),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_fromCache) _staleBanner(),
          if (status != null) status,
        ],
      ),
    );
  }

  Widget _buildBody() {
    // 整块包一个 Builder：三个分支都要用 Scaffold **换过**的内边距（顶栏高度 +
    // 悬浮底栏高度），而 `_buildBody()` 的 context 在 Scaffold 之上，读到的是
    // 状态栏高度。Builder 在 Scaffold 之下，拿到的才是换好的那份。
    return Builder(builder: (ctx) {
      final media = MediaQuery.of(ctx);

      if (_loading) {
        // 骨架屏而不是屏幕正中一个转圈。这里传**整份** media.padding 而不是只让
        // 开顶部：骨架屏外面的（顶栏 + 横幅 + 状态卡）加起来能到 200 出头，只留
        // 顶部的话底下会多出半行灰块压在玻璃底栏上，而且行数是按可用高算的，
        // 高估一行就多画一行。跟加载完的静止状态对齐。
        return Padding(
          padding: media.padding,
          child: const TimetableSkeleton(),
        );
      }
      if (_error != null) {
        // 顶栏（玻璃 + 横幅 + 状态卡）现在最厚能到 200 出头，不自己让开的话
        // 错误文案会藏在玻璃底下。Center 在让开之后的区域里居中。
        return Padding(
          padding: media.padding,
          child: Center(
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
          ),
        );
      }
      // 成功之后整页就是**一条**滚动。
      //
      // 缓存横幅和「现在在上什么」已经搬到顶栏的 `AppBar.bottom` 里了（见
      // `_headerBottom`），这里千万不能再画一遍。搬走还有个几何上的必要性：只要
      // 滚动视图上面还钉着东西，视口就从那块下面开始，课表永远穿不到玻璃底下。
      return RefreshIndicator(
        onRefresh: () => _load(keepSelection: true),
        // 不偏这一下的话，下拉的转圈会出现在顶栏底下被挡住
        edgeOffset: media.padding.top,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          // SingleChildScrollView **不会**自己吃 MediaQuery 的内边距
          // （只有 ListView/BoxScrollView 在 padding 为 null 时才吃），
          // 所以这份要显式接上，否则内容会顶到状态栏和底栏底下
          padding: media.padding,
          child: AnimatedSwitcher(
            // 翻周时淡入 + 轻微上移。key 只跟周次走：同一周内数据刷新（下拉
            // 重载、后台更新）不重播，那时内容是"变"而不是"换了一页"。
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  // 按自身高度的 3% 位移，换算到屏幕上是二十来像素
                  begin: const Offset(0, 0.03),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            // embedded：滚动和内边距都由外面这层管了，网格只负责画自己
            child: TimetableGrid(
              key: ValueKey<int>(_week),
              courses: _visibleCourses,
              week: _week,
              onTap: _showCourseDetail,
              onLongPress: _editNote,
              campusId: _campus,
              embedded: true,
            ),
          ),
        ),
      );
    });
  }

  /// 显示的是缓存内容时顶上挂的一条：点一下立刻重试
  ///
  /// 两种情况长得不一样：
  ///  - 还在忙（_staleReason == null）：说清楚在忙什么，并且给个转圈 ——
  ///    之前这里是个静止的 Icons.sync，配上不动的文字，看着就是死机。
  ///  - 已经失败：静态图标 + 原因 + 缓存年龄，整条可点重试。
  Widget _staleBanner() {
    final scheme = Theme.of(context).colorScheme;
    final busy = _staleReason == null;
    final text = busy
        ? (_loggingIn ? '登录已过期，正在自动重新登录…' : '正在更新课表…')
        : '$_staleReason，${_cacheHint()} · 点此重试';

    // 高度写死（见 `_bannerHeight`）：它住在 AppBar.bottom 里，顶栏的高度得在
    // 建的时候就知道。内边距和内容都按这个数配的，SizedBox 是保证一致性的那一下。
    return SizedBox(
      height: _bannerHeight,
      child: Material(
        color: scheme.surfaceContainerHighest,
        child: InkWell(
          onTap: () => _load(keepSelection: true),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: busy
                      ? CircularProgressIndicator(
                          strokeWidth: 2, color: scheme.primary)
                      : Icon(Icons.cloud_off,
                          size: 16, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
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
              child: Text('删除',
                  style: TextStyle(
                      color: Theme.of(dialogCtx).colorScheme.error)),
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
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
    final subFg = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: subFg),
          const SizedBox(width: 10),
          Text('$label：', style: TextStyle(color: subFg)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
