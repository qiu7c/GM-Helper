import 'dart:async';

import 'package:flutter/material.dart';

import '../config.dart';
import '../models/course.dart';
import '../services/auth_store.dart';
import '../services/auto_login.dart';
import '../services/course_notes.dart';
import '../services/jw_availability.dart';
import '../services/schedule_cache.dart';
import '../services/schedule_diff.dart';
import '../services/schedule_prefs.dart';
import '../services/schedule_service.dart';
import '../widgets/course_colors.dart';
import '../widgets/glass.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/now_status_bar.dart';
import '../widgets/skeleton.dart';
import '../widgets/timetable_grid.dart';
import 'share_image_page.dart';

/// 顶栏「⋮」里收着的功能。
///
/// 按日期跳转**不在此列**：那个是高频操作，留在外面当图标。
enum _More { shareImage }

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

  /// 屏幕上那份 `_result` 是**哪一周**的课表。
  ///
  /// 教务按周返回（第 7 周和第 8 周是两套课程，见 `ScheduleCache._keyOf`），所以
  /// "屏幕上这份"必须带着周次才说得清。两处用到它：
  ///  * 切周时决定要不要重新读缓存（缓存 key 里也带周次了）；
  ///  * 比对课表变化时要求两边同周（`ScheduleDiff.comparable`）。
  int? _resultWeek;
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

  /// 这次失败是**学校那边**的事（教务崩了、或落在维护时段关闭），而不是自己的网络。
  ///
  /// 跟 `_needLogin` 一个道理：只认这个 bool，不去比对文案 —— 文案是给用户看的，
  /// 随时会改。它决定横幅上说什么，也决定整页报错时是普通文案还是那张单独的卡。
  bool _jwDown = false;

  /// 顶上那条横幅现在该不该"点一下去登录"。
  ///
  /// 不能靠比对 `_staleReason` 的文字来判断（那是给用户看的，随时会改），
  /// 而且这个区分是必须的：缓存还在、Cookie 已丢的时候，`_load()` 按设计会继续
  /// 留着缓存而不去登录 —— 横幅要是还调 `_load`，就成了一个点了没反应的按钮。
  bool _needLogin = false;

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
    // 用户主动退出登录：连内存里这份课表一起丢掉
    AuthStore.logoutRevision.addListener(_onLogout);
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
    AuthStore.logoutRevision.removeListener(_onLogout);
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

  void _onLogout() {
    if (!mounted) return;
    // 只清磁盘缓存不够：这个页面活在 `IndexedStack` 里，`_result` 还留在内存里，
    // 切回课表页照样画得出来 —— 退出登录的本意就是"别再让人看到"，那就一起清，
    // 落回"未登录"那个状态（它本来就带「重试」和「重新登录」两个入口）。
    setState(() {
      _result = null;
      _loading = false;
      _error = '未登录';
      _fromCache = false;
      _cacheTime = null;
      _staleReason = null;
      _needLogin = true;
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
    //
    // ⚠ **周次变了也要重读。** 缓存本身是按周存的（key 里带周次）：翻到第 8 周时
    // 该读的是第 8 周那份，而不是继续用第 7 周的顶在那儿。读不到就保持现状，联网
    // 刷新随后会补上。
    final wantWeek = _week.toString();
    final changed = wantTerm != _term ||
        wantCampus != _campus ||
        (_result != null && _resultWeek != _week);
    if (_result == null || changed) {
      final cached = await ScheduleCache.read(
          user: user, term: wantTerm, campus: wantCampus, week: wantWeek);
      if (seq != _loadSeq) return;
      if (cached != null) {
        final at = await ScheduleCache.cachedAt(
            user: user, term: wantTerm, campus: wantCampus, week: wantWeek);
        if (seq != _loadSeq) return;
        setState(() {
          _result = cached;
          _resultWeek = _week;
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

    // ★ Cookie 的检查**放在铺完缓存之后**，这个顺序是有意的。
    //
    // 原来这一判在方法最开头：存的 Cookie 一没就立刻弹登录页、连本地课表都不看
    // 一眼。而安卓上 Cookie 丢并不罕见 —— SharedPreferences 落盘走的是 `apply()`
    // （异步入盘），登录完立刻划掉 App、被系统清理、换机恢复备份都可能没落上，
    // iOS 上这种情况少得多。这正是"iOS 近乎完美、安卓老跳登录页"的一大来源。
    //
    // 现在的顺序：有课表就先留着课表，顶上挂一条"登录已过期"，由用户决定什么时候登。
    final cookie = await AuthStore.getCookie();
    if (seq != _loadSeq) return;
    if (cookie == null || cookie.isEmpty) {
      if (_result != null) {
        setState(() {
          _loading = false;
          _error = null;
          _fromCache = true;
          _staleReason = '登录已过期';
          _needLogin = true;
        });
        // 先别提着手动登录：票本来可能是有效的、只是本地这份丢了 —— 悄悄登一次试试。
        // 结果怎么样都不占屏（见 `_trySilentLogin`），失败就留着上面这条横幅。
        _trySilentLogin();
        return;
      }
      _needLogin = true;
      _goLogin();
      return;
    }
    _needLogin = false;

    // 2) 联网刷新
    try {
      final service = ScheduleService(cookie);

      // 首次加载：向教务同步真实的当前周/总周数/日期
      if (!_calendarLoaded) {
        final cal = await service.fetchCalendar();
        if (cal != null) {
          await SchedulePrefs.instance.applyCalendar(cal);
          _calendarLoaded = true;
          if (!keepSelection) {
            final readWeek = _week;
            _week = cal.currentWeek;
            // 「当前周」被教务纠正过来了。本地那个数是用「学期第一周周一 + 今天」
            // 推出来的，设备日期差一两天就会差出一整周，而教务桌面页的「第X周」
            // 才是准的。
            //
            // 周次一变，缓存键就变了：上面铺的那份属于**纠正前**那一周，而接下来
            // 写缓存、比课表都用纠正后的周次 —— 于是"读的键"和"写的键"永远是两个
            // 周，那份旧缓存再也不会被覆盖。用户看到的就是"第一眼还是旧课表、
            // 缓存时间停在好几天前、还老是说课表有变动"。
            //
            // 所以这里按纠正后的周次重读一次：有就换成它（这才是这一周该显示的），
            // 没有就保持原样，交给下面这次刷新填。
            if (_week != readWeek) {
              final again = await ScheduleCache.read(
                user: user,
                term: wantTerm,
                campus: wantCampus,
                week: _week.toString(),
              );
              if (again != null) {
                final at2 = await ScheduleCache.cachedAt(
                  user: user,
                  term: wantTerm,
                  campus: wantCampus,
                  week: _week.toString(),
                );
                if (!mounted || seq != _loadSeq) return;
                setState(() {
                  _result = again;
                  _resultWeek = _week;
                  _fromCache = true;
                  _cacheTime = at2;
                  _staleReason = null;
                });
              }
            }
          }
        }
      }

      // 这一轮请求的是哪一周：先取快照。后面写缓存、记基线都用它 ——
      // `_week` 在等待期间可能被用户翻走，用快照才不会把结果记到别的周头上。
      final fetchWeek = _week;
      final result = await service.fetch(
        term: wantTerm,
        week: fetchWeek.toString(),
        campus: wantCampus,
      );
      if (!mounted || seq != _loadSeq) return;
      // 屏幕上的那份就是这次的比对基线：铺过缓存时它是缓存，否则是上一次的结果。
      // 第一次打开 App（_result == null）没有基线，下面不比较、也不提示。
      final before = _result;
      // 基线属于哪一周（缓存/上次结果被写进去时的周次）。比对前要和这次请求的周次对齐。
      final beforeWeek = _resultWeek;
      // 学期/校区以**这次读缓存用的那份**（wantTerm/wantCampus）为回落基准。
      //
      // 原来回落的是 `_term`，而 `_term` 可能刚被上面读缓存那一步改成了
      // 「缓存里存的 selectedTerm」—— 那是很久以前那次写进去的值，未必等于
      // 我们这次读用的键。于是一旦服务端回显为空（页面用 JS 设选中项时
      // `_selectedValue` 读不到，很常见），缓存就会写到**另一个键**上：
      // 读的键永远读不到新数据，用户看到的就是"一直是旧课表、缓存时间不前进"。
      final effTerm = result.selectedTerm ?? wantTerm;
      final effCampus = result.selectedCampus ?? wantCampus;
      setState(() {
        _result = result;
        _resultWeek = fetchWeek;
        _term = effTerm;
        _campus = effCampus;
        _loading = false;
        _error = null;
        _fromCache = false;
        _cacheTime = null; // 拿到新的了，之前那份缓存的时间戳作废
        _staleReason = null;
      });
      final fetchWeekStr = fetchWeek.toString();
      await ScheduleCache.write(user: user, term: effTerm, campus: effCampus,
          week: fetchWeekStr, result: result);
      // ★ 再把**这次读缓存用的那个键**也覆盖一遍。
      //
      // 老版本有可能把缓存写到别的键上（比如写的时候用的是"服务端回显的学期"、
      // 读的时候用的是本地偏好里那份），后果是：读的那个键**永远没人写**，
      // 于是每次打开都只能看到很久以前那一份 —— 用户看到的是"一直是旧课表、
      // 缓存时间不前进、还老是说课表有变动"（拿旧表当基线比新数据，必然比出差异）。
      // 那种状态下光把写改对也不够：旧键上的那份还在，下一次读仍然是它。
      //
      // 所以刷新成功之后，把"刚读过的那个键"一起刷成新数据。周次一致时这是安全
      // 的（这份数据本来就属于这个键），代价只是多写一次 prefs；而它保证了一件事：
      // **只要刷新成功过一次，卡住的那份旧缓存就会被顶掉**，不用等下一轮。
      if (fetchWeekStr == wantWeek) {
        await ScheduleCache.write(
            user: user,
            term: wantTerm,
            campus: wantCampus,
            week: wantWeek,
            result: result);
      }
      if (_term != null) await AuthStore.saveLastTerm(_term!);
      if (_campus != null) await AuthStore.saveLastCampus(_campus!);
      SchedulePrefs.instance.sync(term: _term, campus: _campus);
      // 教务中途调课/加课了就说一声。
      //
      // ⚠ **只有同一周的两份才比。** 教务是按周返回的（周次是发给它的 `zc` 参数），
      // 所以翻一周再刷新时，"屏幕上那份"属于**刚翻走的那一周** —— 直接拿来比，必然
      // 报出一堆"新增 N 门、取消 M 门"，可那不是学校调课，只是换了一周。用户看到的
      // 就是"切周弹、重进还弹，一直反复弹窗"。
      //
      // 判据在 `ScheduleDiff.comparable`：两边周次都有、且相等才比，拿不准就不比。
      //
      // 但只靠它不够：`selectedWeek` 是**页面自己回显**的，不保证跟着我们请求的
      // `zc` 走（页面用 JS 设选中项时它甚至可能为空）。真正决定"能不能比"的是
      // 这份数据**是按哪个周次取回来的** —— 也就是 `beforeWeek` 和 `fetchWeek`。
      // 两者不同，说明基线属于别的周，比出来的"新增/取消"全是假的，那正是
      // 「一直反复弹窗、怎么点都还在弹」的来源。
      if (beforeWeek == fetchWeek && ScheduleDiff.comparable(before, result)) {
        final diff = ScheduleDiff.compare(before!.courses, result.courses);
        if (!diff.isEmpty && mounted) _announceDiff(diff);
      }
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      // 教务自己答了个不是课表的页面（维护时段 / 刚重启），而且服务层已经探过
      // 学校那边、确认是它的问题。**这不是用户掉了登录** —— 用户的票是好的，
      // 删了才真的得重新登一次。所以这里既不清会话、也不发起登录，只把口径改成
      // 「教务系统暂时打不开」，等它自己好。
      if (e == ScheduleService.schoolDown) {
        setState(() {
          _loading = false;
          _jwDown = true;
          if (_result != null) {
            _fromCache = true;
          } else {
            _error = null;
          }
        });
        return;
      }
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
        // **屏幕上已经有课表就不弹登录页。**
        //
        // 会话过期 ≠ 课表失效：缓存里那张表还是这学期真实的表。原来的行为是不管有
        // 没有内容都把整页顶掉换成登录页 —— 用户看到的就是"打开 App 课表没了、跳去
        // 登录"，哪怕他从来没点过退出登录。这条也是"没退出登录课表也会消失"那个反馈
        // 的来源。
        //
        // 现在改成：有内容就留着，顶部挂一条"登录已过期"，**同时自己悄悄登一次**
        // （`_trySilentLogin`）。那条横幅自己也是入口 —— 静默登录没成、点它会走
        // `_load`，届时没有 Cookie，才会真的弹登录页。
        if (_result != null) {
          setState(() {
            _loggingIn = false;
            _fromCache = true;
            _staleReason = '登录已过期';
          });
          _trySilentLogin();
          return;
        }
        _goLogin();
        return;
      }
      setState(() {
        _loading = false;
        // 先按原来的口径显示（"网络不可用 / 请求超时"这类），探针回来再改。
        // ⚠ 不能让这里等探针：探测最坏要几秒，而"刷新失败"本来就该立刻出来。
        _jwDown = false;
        if (_result != null) {
          // 缓存还能看，别整屏报错把人吓一跳，顶部挂一行提示就够
          _fromCache = true;
          _staleReason = _whyOffline(e);
        } else {
          // 除了缓存就什么都没有，才需要整屏报错。原因用 _whyOffline 压成人话；
          // 原始异常只进日志 —— 把 "DioException [connection timeout]..." 这种
          // 直接甩给用户，是开发视角，他看不懂也不知道该怎么办。
          debugPrint('课表加载失败: $e');
          _error = '加载失败：${_whyOffline(e)}';
        }
      });
      _probeJwDown(seq);
    }
  }

  /// 出错之后补一次连通性探测：确认是**学校那边**的事，就把口径改成
  /// 「教务系统暂时打不开」。
  ///
  /// 只在"还是最新那一轮"才写回（`seq` 的用法跟 `_load` 里一致）：探测期间用户
  /// 可能已经手动重试成功、或者翻走了一周，这时再改文案就是拿一条过期的判断去
  /// 扣新状态。
  Future<void> _probeJwDown(int seq) async {
    final down = await JwAvailability.schoolLooksDownNow();
    if (!down || !mounted || seq != _loadSeq) return;
    setState(() => _jwDown = true);
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

  /// 教务中途调课/加课了。
  ///
  /// 用弹窗而不是顶部挂一条横幅：这件事**需要被读到**（明天哪节课换了教室），而一条
  /// 几秒后自己消失、或者能被随手划走的东西等于没说。但也不会天天弹 —— 只有真比对出
  /// 差异才走到这里，而比对基线每次刷新都会被覆盖成刚拿到的那一份。
  void _announceDiff(ScheduleDiff diff) {
    const cap = 4; // 每类最多列几条，其余只报个数
    showGlassDialog<void>(
      context: context,
      title: const Text('课表有变化'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('和上次加载的课表比，${diff.summary()}。'),
          const SizedBox(height: 10),
          ...diff.added.take(cap).map((c) => _diffLine('新增', c)),
          ...diff.removed.take(cap).map((c) => _diffLine('取消', c)),
          ...diff.changed.take(cap).map((c) => _diffLine('调整', c)),
          if (diff.total > cap * 3) ...[
            const SizedBox(height: 8),
            Text('…还有 ${diff.total - cap * 3} 项，完整内容看课表。'),
          ],
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }

  Widget _diffLine(String tag, Course c) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          '· $tag ${AppConfig.weekDayNames[c.day - 1]} 第 ${c.period} 大节 ${c.name}'
          '${c.room.isEmpty ? '' : '（${c.room}）'}',
        ),
      );

  /// 会话失效时**先自己悄悄登一次**，不行就只挂着横幅等用户。
  ///
  /// ⚠ 这里用 `AutoLogin.attempt`（走透明路由，全程不占屏），**不是** `_goLogin()`：
  /// 后者在自动登录不可用时会推出手动登录页，把课表顶掉 —— 而那正是之前修掉的毛病
  /// （"屏幕上已经有课表就不弹登录页"）。用户没开自动登录时，一进 App 就被登录页顶掉
  /// 课表，比挂一条横幅糟得多。
  ///
  /// 起因是一条真实反馈：「刚进首页就说登录状态失效，也不会自己尝试静默登录，
  /// 得去『我的』界面点一次登录按钮才自动登上去」。
  ///
  /// 会话过期本来就常有（教务那边到期），可静默登录的入口原来只挂在「我的」页那一个
  /// 按钮上（`ProfilePage._login`）—— 课表页这两条路（票失效 / 本地没票）都只是挂条
  /// 横幅然后 return。于是"能自动登录"这件事，用户得先知道该去哪个页面点一下才享受得到。
  ///
  /// 全部门槛交给 `AutoLogin.isEnabled()`：存了密码、用户没点过退出登录（suppress）、
  /// 本次启动没失败过、成功次数没超上限。不满足就什么都不做 —— 横幅照挂，用户自己决定。
  Future<void> _trySilentLogin() async {
    if (!mounted || _loginOpen || _loggingIn) return;
    if (!await AutoLogin.isEnabled()) return;
    if (!mounted) return;
    _loginOpen = true;
    // 横幅改成"正在自动登录"：这段时间可能十几秒，屏幕上没有别的动静，
    // 不说清楚用户只会以为卡死了（和 `_goLogin` 里同样的理由）。
    setState(() => _loggingIn = true);
    try {
      final res = await AutoLogin.attempt(context);
      if (!mounted) return;
      if (res.ok) {
        // saveCookie 已经通知过 _onAuthChanged，那次 _load 正在跑；
        // 这里再叫一次是保底（seq 机制保证不会互相覆盖）。
        _load();
      }
      // 失败就什么都不做：不设 `_error`、不推登录页。横幅已经写着"登录已过期"，
      // 用户点它、或者去「我的」都能接管。
    } finally {
      _loginOpen = false;
      if (mounted) setState(() => _loggingIn = false);
    }
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
    final w = await showGlassSheet<int>(
      context: context,
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
      // **课表不许穿到顶栏底下去。**
      //
      // 这里原来给 true，理由是"玻璃背后要有东西可糊，不然模糊白做"。但这一页的
      // 顶栏是 `frosted: false` —— 它压根不画玻璃（见下面 appBar 那段），所以这条
      // 理由在这一页根本不成立，换来的只有 bug：内容从顶栏**底下**穿过去，而顶栏
      // 是透明的，往上滑到一定程度，课表格子就和"上课状态"那一段叠在一起了
      // （用户实测反馈：上滑会和上课状态糊成一坨，要有一条分界）。
      //
      // ⚠ **内边距解决不了这件事，别想着靠 padding 兜。**
      // `MediaQuery.padding.top` 是加在 SingleChildScrollView **内部**的，滚动时
      // 它跟着内容一起往上走 —— 内容一滑，那点留白就没了，格子照样顶上去。
      // 只有让**视口本身**从顶栏下沿开始（也就是这里给 false），滚动才真的被裁在
      // 那条线上。这是"边界"，不是"间距"。
      extendBodyBehindAppBar: false,
      appBar: glassAppBar(
        context: context,
        // **顶栏不画玻璃。**
        //
        // 这是一页的主界面：它上面没有别的内容，一块玻璃板的存在本身就在说
        // "这是另一层"—— 于是顶栏和课表之间永远有一道能看见的界。去掉之后
        // 标题、"上课状态"、课表全铺在同一个背景上，顶栏是真的长在页面里。
        //
        // 代价如实说：这是一页里唯一没有玻璃的地方，跟底栏的玻璃不是一套语汇。
        // 但底下没有内容会滚上来（课表总高约 620 逻辑，视口约 934，根本滚不动），
        // 所以不存在"文字压在课块上看不清"的问题。
        frosted: false,
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
            // 左边这一格**故意空着**。原来是「回到本周」按钮，现在搬到不是本周时
            // 右下角浮出来的小提示（见 `_returnThisWeekChip`）—— 顶栏左上角是
            // 离拇指最远的地方，而"回到本周"恰恰是翻远了才要点的东西。
            //
            // 空着不影响中间周切换器居中：两侧都是 `Expanded(flex: 1)`，宽度由
            // flex 定，跟里面放不放东西无关。
            const Expanded(child: SizedBox.shrink()),
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
                      onSelected: (_) => _openShareImage(),
                      itemBuilder: (context) => [
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
      body: Stack(
        // ⚠ `expand` 不能省。Stack 默认是 `loose`，非 Positioned 的子节点会拿到
        // **松约束** —— 下面那个 SingleChildScrollView 就会缩成内容高度，整页
        // 布局直接塌掉。expand 才让它跟直接挂在 Scaffold.body 上一样拿到紧约束。
        fit: StackFit.expand,
        children: [
          _buildBody(),
          // 不是本周时，右下角吸一个「回到本周」
          _returnThisWeekChip(curWeek),
        ],
      ),
    );
  }

  /// 不是本周时，右下角浮出来的「回到本周」。
  ///
  /// 原来它是顶栏左上角的一个图标按钮（已在本周就置灰）。搬下来有两个理由：
  ///  * 它只在"翻走了"的时候才用得上，而那时候最顺手的落点是拇指附近，不是
  ///    屏幕左上角；
  ///  * 顶栏那个位置两边要对称，那个按钮一直在那儿，也等于一直在提示
  ///    "你现在不能回本周"。
  ///
  /// 做成**吸在右下角**的一小块：不跟着课表滚，所以翻多远它都在。
  Widget _returnThisWeekChip(int curWeek) {
    final show = _week != curWeek && !_loading && _error == null;
    // `Positioned.fill` 必须是 Stack 的**直接**子节点，所以这里不能再包一层；
    // 里面那层 Builder 是为了拿到 **Scaffold 换过**的内边距（`extendBody` 那套
    // 把 padding.bottom 换成了悬浮底栏的实测高度）。
    return Positioned.fill(
      child: Builder(builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        final media = MediaQuery.of(ctx);
        return Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding:
                EdgeInsets.only(right: 12, bottom: media.padding.bottom + 10),
            child: AnimatedSlide(
              // 从右边滑进来。1.4 = 自身宽度的 1.4 倍，足够完全退到屏幕外，
              // 由 Stack 的 Clip.hardEdge 裁掉
              offset: show ? Offset.zero : const Offset(1.4, 0),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: show ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                // ⚠ 透明度归零之后**仍然参与命中测试**，不挡住的话会在看不见的
                // 地方拦住课表格子
                child: IgnorePointer(
                  ignoring: !show,
                  child: DecoratedBox(
                    // 阴影必须画在玻璃**外面**：GlassPanel 自己会 ClipRRect，
                    // 画在里面会一起被裁掉，那这颗胶囊就成了贴在课表上的平板。
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.16),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: GlassPanel(
                      borderRadius: BorderRadius.circular(22),
                      // 「厚」毛玻璃：比全局那档（AppTheme.glassFill / glassBlur）
                      // 更实、更糊。全局那两个数是顶栏和底栏的量，跟着调会把整页
                      // 的玻璃层次一起动掉，所以这颗胶囊单独给值。
                      fillOpacity: 0.62,
                      blur: 30,
                      // 水波纹得有 Material 才画得出来。原来那层 Material 连同它的
                      // 实心底色一起被玻璃取代了，所以这里只留透明的一层。
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          onTap: () => _goWeek(curWeek),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.today_outlined,
                                    size: 16, color: scheme.onSurface),
                                const SizedBox(width: 6),
                                Text(
                                  '回到本周',
                                  // 底色不再是 primaryContainer，字色跟着换成
                                  // onSurface —— 玻璃底其实是 surface 的渐变
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onSurface,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }),
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

  /// 整页报错时显示的东西。
  ///
  /// 「教务系统自己不在」单独给一张卡，而不是把「加载失败：网络不可用」再念一遍：
  /// 这条信息对用户是有用的 —— 它说明**问题不在他这边**，刷新、检查网络都没意义，
  /// 等一会儿再来就行。学校教务在维护时段关闭是常态。
  Widget _errorView() {
    final scheme = Theme.of(context).colorScheme;
    final retry = FilledButton(
      onPressed: () => _load(keepSelection: true),
      child: const Text('重试'),
    );

    if (!_jwDown) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          retry,
          TextButton(onPressed: _goLogin, child: const Text('重新登录')),
        ],
      );
    }

    return ConstrainedBox(
      // 卡不能跟着屏幕一起变宽，宽屏上会成一条横幅
      constraints: const BoxConstraints(maxWidth: 320),
      child: GlassPanel(
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.school_outlined,
                  size: 34, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                '教务系统暂时打不开',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '学校教务系统有时会崩溃，或者在维护时段关闭。\n'
                '这不是你这边的问题，过一会儿再来。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              retry,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    // 整块包一个 Builder：三个分支都要用 Scaffold **换过**的内边距（悬浮底栏
    // 换过的那份 bottom），而 `_buildBody()` 的 context 在 Scaffold 之上，读到的
    // 是原始那份。Builder 在 Scaffold 之下，拿到的才是换好的。
    //
    // ⚠ 顶部**不要**再用 media.padding.top：视口已经从顶栏下沿开始了
    //（见 `extendBodyBehindAppBar: false` 那段），让开一个顶部内边距就是白空一截。
    return Builder(builder: (ctx) {
      final media = MediaQuery.of(ctx);
      // 只留 4 的呼吸位，和加载完之后的课表对齐（三态用同一份，切换时不跳）
      final pad = media.padding.copyWith(top: 4);

      if (_loading) {
        // 骨架屏而不是屏幕正中一个转圈。bottom 必须留着：行数是按可用高算的，
        // 高估一行就会多画一行灰块压在玻璃底栏上。
        return Padding(
          padding: pad,
          child: const TimetableSkeleton(),
        );
      }
      if (_error != null) {
        // Center 在让开之后的区域里居中
        return Padding(
          padding: pad,
          child: Center(child: _errorView()),
        );
      }
      // 成功之后整页就是**一条**滚动。
      //
      // 缓存横幅和「现在在上什么」已经搬到顶栏的 `AppBar.bottom` 里了（见
      // `_headerBottom`），这里千万不能再画一遍。搬走还有个几何上的必要性：只要
      // 滚动视图上面还钉着东西，视口就从那块下面开始，课表永远穿不到玻璃底下。
      return RefreshIndicator(
        onRefresh: () => _load(keepSelection: true),
        // 视口就是从顶栏下沿开始的，转圈出现在视口顶部即可（0），不用再往下推
        // 一个 media.padding.top —— 那会让它悬在课表中间。
        edgeOffset: 0,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          // SingleChildScrollView **不会**自己吃 MediaQuery 的内边距
          // （只有 ListView/BoxScrollView 在 padding 为 null 时才吃），
          // 所以这份要显式接上，否则内容会顶到状态栏和底栏底下
          //
          // ⚠ 顶部只让开 4。原来让 10，是因为状态卡自己有底色、又和"今天"那一列
          // 的高亮块同为 primaryContainer，两块同色圆角矩形贴一起会黏住。
          // 现在状态卡**没有底色也没有描边**、高亮块改成了淡红强调色，同色相黏
          // 这件事不存在了，所以间隔收到 4 —— 顶栏、状态、课表要"几乎融为一体"，
          // 留太大就又把它们切开了。
          // 视口已经从顶栏下沿开始了（见 extendBodyBehindAppBar 那段），所以这里
        // **不能再让开一个 media.padding.top** —— 顶栏下面的那 60 来像素本来就是
        // 顶栏自己占的，再让一次课表会凭空矮一截。
        //
        // 只留 4 的呼吸位：顶栏、状态、课表要"几乎融为一体"，留大了又把它们切开。
        padding: media.padding.copyWith(top: 4),
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
  /// 顶上那条横幅点一下：该登录就去登录，否则重试刷新。
  void _onBannerTap() {
    if (_needLogin) {
      _goLogin();
      return;
    }
    _load(keepSelection: true);
  }

  Widget _staleBanner() {
    final scheme = Theme.of(context).colorScheme;
    final busy = _staleReason == null;
    // 教务系统自己不在的时候说法要变：「网络不可用」会把锅甩给用户，而这种时候
    // 他做什么都没用（理由见 JwAvailability 那段注释）。
    final reason = _jwDown ? '教务系统暂时打不开' : _staleReason;
    final text = busy
        ? (_loggingIn ? '登录已过期，正在自动重新登录…' : '正在更新课表…')
        : '$reason，${_cacheHint()} · 点此重试';

    // 高度写死（见 `_bannerHeight`）：它住在 AppBar.bottom 里，顶栏的高度得在
    // 建的时候就知道。内边距和内容都按这个数配的，SizedBox 是保证一致性的那一下。
    return SizedBox(
      height: _bannerHeight,
      // **不画底色。**
      //
      // 这里原来铺的是 `surfaceContainerHighest` —— 一条实心灰带。而这一页的顶栏是
      // **刻意不画玻璃**的（理由见 `glassAppBar` 那段注释：标题、上课状态、课表要
      // 铺在同一层背景上，中间不该有一道能看见的界）。横幅再铺一块实心色，就是在
      // 那层背景上贴了一张卡，跟整页不是一个语汇。
      //
      // 去掉底色是安全的：课表总高比视口矮、滚不上来（同上），不存在"文字压在课块
      // 上看不清"。用 `MaterialType.transparency` 而不是把 Material 去掉 ——
      // InkWell 的水波纹要靠它。
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: _onBannerTap,
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
                      : Icon(_jwDown ? Icons.school_outlined : Icons.cloud_off,
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
    final result = await showGlassDialog<String>(
      context: context,
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
            onPressed: () => Navigator.pop(context, '__delete__'),
            child: Text('删除',
                style:
                    TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, ctrl.text),
          child: const Text('保存'),
        ),
      ],
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
    showGlassSheet(
      context: context,
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
