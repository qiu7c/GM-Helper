import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../config.dart';
import '../models/course.dart';

/// 拉取并解析教务系统课表
class ScheduleService {
  final Dio _dio;

  ScheduleService(String cookie)
      : _dio = Dio(BaseOptions(
          followRedirects: false,
          // 教务系统未登录会重定向到 SSO；这里把 3xx 也当正常返回，便于识别登录失效
          validateStatus: (s) => s != null && s < 500,
          headers: {
            'Cookie': cookie,
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
            'Referer': '${AppConfig.jwHost}/jsxsd/framework/xsMain.jsp',
          },
        ));

  /// 抛出该异常表示会话已失效，需要重新登录
  static const sessionExpired = 'SESSION_EXPIRED';

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

    // 登录失效：教务系统会 302 跳转到登录页，或返回登录页面文本
    final body = resp.data ?? '';
    final isRedirect = resp.statusCode != null &&
        resp.statusCode! >= 300 &&
        resp.statusCode! < 400;
    if (isRedirect || body.contains('用户登录') || body.contains('login.jsp')) {
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
