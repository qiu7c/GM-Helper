import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../config.dart';
import 'session_guard.dart';

/// 学籍/个人信息
class Profile {
  /// 姓名
  final String name;

  /// 学号
  final String studentId;

  /// 详细字段（有序），如 所属院系/专业名称/班级名称 等。
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
          connectTimeout: AppConfig.connectTimeout,
          receiveTimeout: AppConfig.receiveTimeout,
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

  /// 学生桌面页（含 .middletopttxlr 个人信息块：姓名/学号/院系/专业/班级）
  static const String _desktopUrl =
      '${AppConfig.jwHost}/jsxsd/framework/xsMain_new.jsp';

  /// 教务主框架页（兜底取姓名/学号）
  static const String _frameUrl =
      '${AppConfig.jwHost}/jsxsd/framework/xsMain.jsp';

  /// 学籍卡片页（备用，桌面页拿不到时再试）
  static const String _xsxxUrl = '${AppConfig.jwHost}/jsxsd/grxx/xsxx';

  /// 获取个人信息。优先解析桌面页的 .middletopttxlr 块，失败再退回框架页。
  Future<Profile> fetch() async {
    String name = '';
    String studentId = '';
    final fields = <MapEntry<String, String>>[];

    /// 是否真的拿到过一次"服务端的 200 页面"。
    /// 网络错误会被下面的 catch 吞掉，那种情况不该判成会话失效
    /// （否则一断网就把登录态清了）。只有确实收到了页面、却什么都没解析出来，
    /// 才说明拿到的不是业务页。
    var gotPage = false;

    // 1) 桌面页：一个块拿全部信息
    try {
      final resp = await _dio.get<String>(_desktopUrl);
      final body = resp.data ?? '';
      _throwIfLoggedOut(resp.statusCode, body);
      if (resp.statusCode == 200) gotPage = true;
      final parsed = _parseDesktop(body);
      for (final e in parsed) {
        switch (e.key) {
          case '学生姓名':
          case '姓名':
            name = e.value;
            break;
          case '学生编号':
          case '学号':
            studentId = e.value;
            break;
          default:
            fields.add(e);
        }
      }
    } catch (e) {
      if (e == sessionExpired) rethrow;
    }

    // 2) 兜底：桌面页没拿到姓名/学号时，从框架页补
    if (name.isEmpty || studentId.isEmpty) {
      try {
        final frame = await _dio.get<String>(_frameUrl);
        final body = frame.data ?? '';
        _throwIfLoggedOut(frame.statusCode, body);
        if (frame.statusCode == 200) gotPage = true;
        if (name.isEmpty) name = _extractFrameName(body);
        if (studentId.isEmpty) studentId = _extractFrameStudentId(body);
      } catch (e) {
        if (e == sessionExpired) rethrow;
      }
    }

    // 收到了页面，却连姓名、学号、任何一项信息都没解析出来 —— 那不是业务页，
    // 多半是会话超时的过渡页（它不跳转、也没有 CAS 表单，_throwIfLoggedOut
    // 认不出来）。真账号一定有姓名，所以"全空"只可能是没登进去。
    // 不在这里拦住的话，「我的」页会显示成"已登录但所有字段都是空的"。
    if (gotPage && name.isEmpty && studentId.isEmpty && fields.isEmpty) {
      throw sessionExpired;
    }

    return Profile(name: name, studentId: studentId, fields: fields);
  }

  void _throwIfLoggedOut(int? status, String body) {
    if (SessionGuard.looksLoggedOut(status, body)) throw sessionExpired;
  }

  /// 解析桌面页 .middletopttxlr 块：
  /// 每行 = <div><div class="...middletopdwxxtit">标签：</div>
  ///              <div class="middletopdwxxcont">值</div></div>
  List<MapEntry<String, String>> _parseDesktop(String html) {
    final doc = html_parser.parse(html);
    final result = <MapEntry<String, String>>[];

    final block = doc.querySelector('.middletopttxlr');
    if (block == null) return result;

    final titles = block.querySelectorAll('.middletopdwxxtit');
    for (final title in titles) {
      final label = _clean(title.text).replaceAll(RegExp(r'[:：]\s*$'), '');
      if (label.isEmpty) continue;
      // 值 = 同一行内紧跟的 .middletopdwxxcont
      final row = title.parent;
      final cont = row?.querySelector('.middletopdwxxcont');
      final value = _clean(cont?.text ?? '');
      if (value.isEmpty) continue;
      result.add(MapEntry(label, value));
    }
    return result;
  }

  /// 从框架页 <span class="glyphicon-class ckgrxx"><a>陈健升</a></span> 取姓名
  String _extractFrameName(String html) {
    final doc = html_parser.parse(html);
    return doc.querySelector('.ckgrxx')?.text.trim() ?? '';
  }

  /// 从框架页内联 JS `var userid = '202603650032';` 取学号
  String _extractFrameStudentId(String html) {
    final m = RegExp(r"var\s+userid\s*=\s*'([^']+)'").firstMatch(html);
    return m?.group(1)?.trim() ?? '';
  }

  String _clean(String s) =>
      s.replaceAll(' ', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}
