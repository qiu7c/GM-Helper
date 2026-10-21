import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../config.dart';
import '../models/course.dart';
import 'jw_availability.dart';
import 'session_guard.dart';

/// 拉取并解析教务系统课表
class ScheduleService {
  final Dio _dio;

  ScheduleService(String cookie)
      : _dio = Dio(BaseOptions(
          followRedirects: false,
          // 教务系统未登录会重定向到 SSO；这里把 3xx 也当正常返回，便于识别登录失效
          validateStatus: (s) => s != null && s < 500,
          connectTimeout: AppConfig.connectTimeout,
          receiveTimeout: AppConfig.receiveTimeout,
          headers: {
            'Cookie': cookie,
            'User-Agent': AppConfig.userAgent,
            'Referer': '${AppConfig.jwHost}/jsxsd/framework/xsMain.jsp',
          },
        ));

  /// 抛出该异常表示会话已失效，需要重新登录
  static const sessionExpired = 'SESSION_EXPIRED';

  /// 抛出该异常表示**不是**用户掉了登录，而是学校那边答不出业务页面
  /// （维护时段、刚重启、502 之后的兜底页）。见 `fetch` 里那段判据。
  static const schoolDown = 'SCHOOL_DOWN';

  /// 课表页的**自有**结构锚点：真页面上至少有其中一个。
  ///
  /// 用来识别"会话超时的过渡页"—— 那种页面既不跳转也没有 CAS 表单，
  /// [SessionGuard.looksLoggedOut] 认不出来，会被当成一份空课表解析掉。
  /// 详见 [SessionGuard.containsAnyOf]。
  ///
  /// 只收这三个 id，是因为它们是课表页自己渲染出来的控件，别处不会有。
  /// 别再往里加 'jsxsd' 这种路径前缀之类的宽泛词：过渡页里也可能出现，
  /// 一旦命中就整条判断失效，等于白加 —— 判断要**严**，宁可误报也不能漏报。
  static const List<String> _timetableAnchors = [
    'xnxq01id', // 学年学期下拉框
    'kbjcmsid', // 校区(时间模式)下拉框
    'kbtable', // 课表本体
  ];

  /// 教务桌面页（含 .middletopleftrqbox 当前周/日期块）
  static const String _desktopUrl =
      '${AppConfig.jwHost}/jsxsd/framework/xsMain_new.jsp';

  /// 拉取学期日历（当前周/总周数/当前日期）。失败返回 null（不影响课表）。
  Future<TermCalendar?> fetchCalendar() async {
    try {
      final resp = await _dio.get<String>(_desktopUrl);
      final body = resp.data ?? '';
      // 未登录/会话失效时拿不到校历，返回 null 交给上层（不在这里清 Cookie）
      if (SessionGuard.looksLoggedOut(resp.statusCode, body)) return null;

      final doc = html_parser.parse(body);

      // 第X周 / Y周
      int? cur;
      int? total;
      final showWeek = doc.querySelector('#li_showWeek');
      if (showWeek != null) {
        final txt = showWeek.text; // "第3周/20周"
        final mCur = RegExp(r'第\s*(\d+)\s*周').firstMatch(txt);
        cur = mCur != null ? int.tryParse(mCur.group(1)!) : null;
        final mTotal = RegExp(r'/\s*(\d+)\s*周').firstMatch(txt);
        total = mTotal != null ? int.tryParse(mTotal.group(1)!) : null;
      }

      // 当前日期
      DateTime? date;
      final rq = doc.querySelector('#rq');
      final rqVal = rq?.attributes['value'] ?? '';
      final mDate = RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(rqVal);
      if (mDate != null) {
        date = DateTime(
          int.parse(mDate.group(1)!),
          int.parse(mDate.group(2)!),
          int.parse(mDate.group(3)!),
        );
      }

      if (cur == null || date == null) return null;
      return TermCalendar(
        currentWeek: cur,
        totalWeeks: total ?? 20,
        date: date,
      );
    } catch (_) {
      return null;
    }
  }

  /// 查询课表。
  /// [term] 学年学期(如 2026-2027-1)，[week] 周次(1..)，[campus] 时间模式id。
  /// 传 null 表示用服务器默认值。
  Future<ScheduleResult> fetch({
    String? term,
    String? week,
    String? campus,
  }) async {
    final data = <String, dynamic>{};
    if (term != null) data['xnxq01id'] = term;
    if (week != null) data['zc'] = week;
    if (campus != null) data['kbjcmsid'] = campus;

    final Response<String> resp;
    if (data.isEmpty) {
      resp = await _dio.get<String>(AppConfig.scheduleUrl);
    } else {
      resp = await _dio.post<String>(
        AppConfig.scheduleUrl,
        data: data,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
        ),
      );
    }

    final body = resp.data ?? '';
    // 1) 明确的登录失效：302 跳到统一身份认证，或直接返回登录页
    if (SessionGuard.looksLoggedOut(resp.statusCode, body)) {
      throw sessionExpired;
    }
    // 2) 拿到了 200，但正文里一个课表页的锚点都没有 —— 这不是课表页。
    //    会话超时的过渡页就长这样：不跳转、没登录表单，光看状态码和登录页特征
    //    都发现不了。不在这里拦住的话，_parse 会安静地解析出一份空课表，
    //    用户看到的是"还显示已登录，但课表全空"，刷新多少次都一样。
    //
    //    只在 200 上判：网络错误/5xx 会直接抛异常走各自的错误处理，
    //    那种情况不该误判成会话失效（否则一断网就把登录态清了）。
    if (resp.statusCode == 200 &&
        !SessionGuard.containsAnyOf(body, _timetableAnchors)) {
      // 拿到的不是课表页。这有两种可能，而它们对用户意味着完全相反的事：
      //   1. 会话真的失效了（教务未登录时回的就是一个 200 的登录页）；
      //   2. 教务自己出了状况 —— 维护时段、刚重启、502 之后的兜底页 —— 它回的
      //      页面同样既不是课表、也没有登录页特征。
      //
      // 实测"真失效"那种情况正文里有「请先登录系统」，已经被 [SessionGuard] 在
      // 上面那条拦住了；能走到这里的大多是第 2 种。
      //
      // 为什么必须分开：清会话是不可逆的（用户的票会被删掉、还要被推去登录），
      // 可它**未必**是用户的错。所以先探一次学校那边，探到学校有问题就按
      // "教务系统暂时打不开"报，绝不删票、也不发起登录。探测结果有 20 秒缓存
      // （见 [JwAvailability]），用户连点刷新也不会拿学校服务器当压测对象。
      if (await JwAvailability.schoolLooksDownNow()) {
        throw schoolDown;
      }
      throw sessionExpired;
    }

    return _parse(body);
  }

  ScheduleResult _parse(String htmlText) {
    final doc = html_parser.parse(htmlText);

    final terms = _parseOptions(doc, '#xnxq01id');
    final weeks = _parseOptions(doc, '#zc');
    final campuses = _parseOptions(doc, '#kbjcmsid');

    final table = doc.querySelector('#kbtable');
    final courses = <Course>[];
    String remark = '';

    if (table != null) {
      final rows = table.querySelectorAll('tr');
      // 第 0 行是表头(星期)，之后每行是一个大节；最后可能是备注行
      var period = 0;
      for (var i = 1; i < rows.length; i++) {
        final row = rows[i];
        final cells = row.querySelectorAll('td');

        // 备注行：形如 <th>备注:</th><td colspan=7>...</td>
        final th = row.querySelector('th');
        if (th != null && th.text.contains('备注')) {
          remark = cells.isNotEmpty ? cells.first.text.trim() : '';
          continue;
        }

        if (cells.length < 7) continue;
        period++;
        for (var d = 0; d < 7 && d < cells.length; d++) {
          final day = d + 1;
          _parseCell(cells[d], day, period, courses);
        }
      }
    }

    return ScheduleResult(
      courses: courses,
      terms: terms,
      weeks: weeks,
      campuses: campuses,
      selectedTerm: _selectedValue(doc, '#xnxq01id'),
      selectedWeek: _selectedValue(doc, '#zc'),
      selectedCampus: _selectedValue(doc, '#kbjcmsid'),
      remark: remark,
      tableFound: table != null,
    );
  }

  /// 解析单元格。放大模式下详细信息在 class="kbcontent" 的 div 里。
  /// 一个单元格可能有多门课，用 <br><br> 或分隔线区分，这里按 "---------" 或
  /// 直接把每个 kbcontent 里的多段拆开。
  void _parseCell(dom.Element cell, int day, int period, List<Course> out) {
    // 优先取放大版（含老师）的详细 div：class 恰为 "kbcontent"（非 sykb2 空div）
    final divs = cell.querySelectorAll('div.kbcontent');
    for (final div in divs) {
      // 跳过实验课占位空 div（class 含 sykb2 且无文本）
      if (div.classes.contains('sykb2')) continue;
      final parsed = _parseContentDiv(div, day, period);
      out.addAll(parsed);
    }
  }

  /// 解析一个 kbcontent div，内部可能有多门课（用 <br><br> 空行分隔）
  List<Course> _parseContentDiv(dom.Element div, int day, int period) {
    final result = <Course>[];

    // 将 div 内容按 innerHtml 里的分隔（连续两个<br>之间为一门课）来切
    // 更稳妥：遍历子节点，遇到"文本 + 若干 font"归为一组
    final blocks = _splitBlocks(div);
    for (final block in blocks) {
      final course = _parseBlock(block, day, period);
      if (course != null) result.add(course);
    }
    return result;
  }

  /// 把一个 div 的子节点切成若干"课程块"。
  /// 结构规律：课程名(纯文本) 后跟若干 <font title="...">，再 <br>，
  /// 多门课之间通常有额外空行。这里以"出现新的纯文本课名"作为新块的开始。
  List<List<dom.Node>> _splitBlocks(dom.Element div) {
    final blocks = <List<dom.Node>>[];
    List<dom.Node> current = [];
    // 括号()包裹的是教学班,也是文本节点,不能当新课名;
    // 只有当前块已含font(课程详情)后再遇新非括号文本,才算下一门课
    var hasFont = false;

    for (final node in div.nodes) {
      final isText = node.nodeType == dom.Node.TEXT_NODE;
      final text = node.text?.trim() ?? '';
      // 纯文本且非空、非 &nbsp;，视为一门新课的课名 -> 开新块
      final isCourseNameXX =
          isText && text.isNotEmpty && text != ' ';
      final isFont = node is dom.Element && node.localName == 'font';
      final isParen = isText && text.startsWith('(') && text.endsWith(')');
      if (isCourseNameXX && !isParen && hasFont && current.isNotEmpty) {
        blocks.add(List.of(current));
        current = [];
        hasFont = false;
      }
      current.add(node);
      if (isFont) hasFont = true;
    }
    if (current.isNotEmpty) blocks.add(current);
    return blocks;
  }

  Course? _parseBlock(List<dom.Node> nodes, int day, int period) {
    String name = '';
    String teacher = '';
    String room = '';
    String teachingClass = '';
    String rawWeeks = '';
    String sectionRange = '';

    for (final node in nodes) {
      if (node.nodeType == dom.Node.TEXT_NODE) {
        final t = node.text?.trim() ?? '';
        if (t.isEmpty || t == ' ') continue;
        // 括号包裹的通常是教学班信息，如 "(天河足球020102)"
        if (t.startsWith('(') && t.endsWith(')')) {
          teachingClass = t.substring(1, t.length - 1);
        } else if (name.isEmpty) {
          name = t;
        }
      } else if (node is dom.Element && node.localName == 'font') {
        final title = node.attributes['title'] ?? '';
        final val = node.text.trim();
        switch (title) {
          case '老师':
            teacher = val;
            break;
          case '教室':
            room = val;
            break;
          case '周次(节次)':
            rawWeeks = val;
            sectionRange = _extractSection(val);
            break;
          default:
            // 有些教学班信息也可能放在无 title 的 font 里
            if (title.isEmpty && teachingClass.isEmpty && val.startsWith('(')) {
              teachingClass = val.replaceAll(RegExp(r'^\(|\)$'), '');
            }
        }
      }
    }

    if (name.isEmpty) return null;

    return Course(
      name: name,
      teacher: teacher,
      room: room,
      teachingClass: teachingClass,
      rawWeeks: rawWeeks,
      weeks: _parseWeeks(rawWeeks),
      day: day,
      period: period,
      sectionRange: sectionRange,
    );
  }

  /// 从 "3-6,10-19(周)[01-02节]" 提取小节 "01-02节"
  String _extractSection(String raw) {
    final m = RegExp(r'\[([^\]]+)\]').firstMatch(raw);
    return m != null ? m.group(1)! : '';
  }

  /// 解析周次字符串为具体周列表。
  /// 支持："3-7,10-19(周)"、"1,3,5(周)"、"1-16(单周)"、"2-16(双周)"
  List<int> _parseWeeks(String raw) {
    final weeks = <int>{};
    if (raw.isEmpty) return [];

    final isOdd = raw.contains('单');
    final isEven = raw.contains('双');

    // 去掉 (周)/(单周)/(双周) 及 [..节]
    var s = raw.replaceAll(RegExp(r'\([^)]*\)'), '');
    s = s.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    s = s.trim();

    for (final part in s.split(',')) {
      final p = part.trim();
      if (p.isEmpty) continue;
      if (p.contains('-')) {
        final se = p.split('-');
        final start = int.tryParse(se[0].trim());
        final end = int.tryParse(se.length > 1 ? se[1].trim() : '');
        if (start != null && end != null) {
          for (var w = start; w <= end; w++) {
            if (isOdd && w.isEven) continue;
            if (isEven && w.isOdd) continue;
            weeks.add(w);
          }
        }
      } else {
        final w = int.tryParse(p);
        if (w != null) weeks.add(w);
      }
    }
    final list = weeks.toList()..sort();
    return list;
  }

  List<SelectOption> _parseOptions(dom.Document doc, String selector) {
    final sel = doc.querySelector(selector);
    if (sel == null) return [];
    return sel
        .querySelectorAll('option')
        .map((o) => SelectOption(
              o.attributes['value'] ?? '',
              o.text.trim(),
            ))
        .where((o) => o.value.isNotEmpty)
        .toList();
  }

  String? _selectedValue(dom.Document doc, String selector) {
    final sel = doc.querySelector(selector);
    if (sel == null) return null;
    final opt = sel.querySelector('option[selected]');
    return opt?.attributes['value'];
  }
}
