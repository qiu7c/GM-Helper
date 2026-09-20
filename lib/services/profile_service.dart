import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../config.dart';

/// 学籍/个人信息
class Profile {
  /// 姓名
  final String name;

  /// 学号
  final String studentId;

  /// 详细学籍字段（有序），如 学院/专业/班级/年级/性别 等。
  /// key=字段名(去掉冒号)，value=字段值。
  final List<MapEntry<String, String>> fields;

  const Profile({
    required this.name,
    required this.studentId,
    this.fields = const [],
  });

  bool get isEmpty => name.isEmpty && studentId.isEmpty && fields.isEmpty;
}

/// 拉取并解析教务系统的个人/学籍信息
class ProfileService {
  final Dio _dio;

  ProfileService(String cookie)
      : _dio = Dio(BaseOptions(
          followRedirects: false,
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

  /// 学籍卡片页
  static const String _xsxxUrl = '${AppConfig.jwHost}/jsxsd/grxx/xsxx';

  /// 教务主框架页（含姓名/学号，最稳）
  static const String _frameUrl =
      '${AppConfig.jwHost}/jsxsd/framework/xsMain.jsp';

  /// 只关心的学籍字段（顺序即展示顺序）。value 侧命中即收录，避免解析出无关内容。
  static const List<String> _wantedLabels = [
    '姓名',
    '学号',
    '性别',
    '曾用名',
    '出生日期',
    '民族',
    '政治面貌',
    '身份证号',
    '学院',
    '系部',
    '院系',
    '专业',
    '专业方向',
    '班级',
    '行政班',
    '年级',
    '学制',
    '培养层次',
    '学籍状态',
    '入学日期',
    '联系电话',
    '手机号码',
    '电子邮箱',
    'QQ',
    '家庭住址',
    '籍贯',
  ];

  /// 获取个人信息。先取框架页拿姓名+学号，再取学籍卡片补充详细字段。
  Future<Profile> fetch() async {
    // 1) 框架页：姓名 + 学号（最稳定）
    String name = '';
    String studentId = '';
    try {
      final frame = await _dio.get<String>(_frameUrl);
      final body = frame.data ?? '';
      _throwIfLoggedOut(frame.statusCode, body);
      name = _extractFrameName(body);
      studentId = _extractFrameStudentId(body);
    } catch (e) {
      if (e == sessionExpired) rethrow;
      // 框架页失败不致命，继续尝试学籍卡片
    }

    // 2) 学籍卡片：详细字段
    final fields = <MapEntry<String, String>>[];
    try {
      final resp = await _dio.get<String>(_xsxxUrl);
      final body = resp.data ?? '';
      _throwIfLoggedOut(resp.statusCode, body);
      final parsed = _parseCard(body);
      fields.addAll(parsed);

      // 用卡片里的姓名/学号补齐框架页缺失的部分
      for (final e in parsed) {
        if (e.key == '姓名' && name.isEmpty) name = e.value;
        if (e.key == '学号' && studentId.isEmpty) studentId = e.value;
      }
    } catch (e) {
      if (e == sessionExpired) rethrow;
      // 学籍卡片失败：至少还能展示姓名+学号
    }

    // fields 里已含姓名/学号时，头部单独展示，列表里去掉避免重复
    final rest = fields
        .where((e) => e.key != '姓名' && e.key != '学号')
        .toList();

    return Profile(name: name, studentId: studentId, fields: rest);
  }

  void _throwIfLoggedOut(int? status, String body) {
    final isRedirect = status != null && status >= 300 && status < 400;
    if (isRedirect ||
        body.contains('用户登录') ||
        body.contains('login.jsp') ||
        body.contains('账号登录')) {
      throw sessionExpired;
    }
  }

  /// 从框架页 <span class="glyphicon-class ckgrxx"><a>陈健升</a></span> 取姓名
  String _extractFrameName(String html) {
    final doc = html_parser.parse(html);
    final el = doc.querySelector('.ckgrxx');
    final t = el?.text.trim() ?? '';
    return t;
  }

  /// 从框架页内联 JS `var userid = '202603650032';` 取学号
  String _extractFrameStudentId(String html) {
    final m = RegExp(r"var\s+userid\s*=\s*'([^']+)'").firstMatch(html);
    return m?.group(1)?.trim() ?? '';
  }

  /// 解析学籍卡片页：把表格里的「标签→值」成对提取。
  /// 兼容两种常见结构：
  ///  a) 同一行多对：<td>标签</td><td>值</td><td>标签</td><td>值</td>...
  ///  b) 单元格内自带冒号：<td>标签：值</td>
  List<MapEntry<String, String>> _parseCard(String html) {
    final doc = html_parser.parse(html);
    final result = <MapEntry<String, String>>[];
    final seen = <String>{};

    void add(String label, String value) {
      label = _clean(label).replaceAll(RegExp(r'[:：]\s*$'), '');
      value = _clean(value);
      if (label.isEmpty || value.isEmpty) return;
      if (!_wantedLabels.contains(label)) return;
      if (seen.contains(label)) return;
      seen.add(label);
      result.add(MapEntry(label, value));
    }

    // 收集所有单元格文本（td 与 th），按文档顺序
    final cells = doc
        .querySelectorAll('td, th')
        .map((e) => _clean(e.text))
        .toList();

    for (var i = 0; i < cells.length; i++) {
      final cur = cells[i];
      if (cur.isEmpty) continue;

      // 结构 b：单元格内 "标签：值"
      final inline = RegExp(r'^(.{1,8}?)[:：]\s*(.+)$').firstMatch(cur);
      if (inline != null) {
        final lbl = inline.group(1)!;
        if (_wantedLabels.contains(_clean(lbl))) {
          add(lbl, inline.group(2)!);
          continue;
        }
      }

      // 结构 a：当前单元格是已知标签，取下一非空单元格为值
      final lblCandidate = cur.replaceAll(RegExp(r'[:：]\s*$'), '');
      if (_wantedLabels.contains(lblCandidate)) {
        for (var j = i + 1; j < cells.length; j++) {
          if (cells[j].isNotEmpty) {
            // 下一格若又是标签，说明本标签无值，跳过
            final next = cells[j].replaceAll(RegExp(r'[:：]\s*$'), '');
            if (_wantedLabels.contains(next)) break;
            add(lblCandidate, cells[j]);
            break;
          }
        }
      }
    }

    // 按 _wantedLabels 的顺序排序，展示更整齐
    result.sort((a, b) => _wantedLabels
        .indexOf(a.key)
        .compareTo(_wantedLabels.indexOf(b.key)));
    return result;
  }

  String _clean(String s) =>
      s.replaceAll(' ', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}
