import 'dart:math';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:html/parser.dart' as html_parser;

import '../config.dart';

/// 登录失败异常，message 为可展示给用户的原因
class CasLoginException implements Exception {
  final String message;
  CasLoginException(this.message);
  @override
  String toString() => message;
}

/// 纯 HTTP 模拟统一身份认证(CAS)登录。
///
/// 流程与浏览器一致：
///  1. GET 登录页 → 取动态令牌(lt/execution) 与密码加密盐(pwdDefaultEncryptSalt)
///  2. 按 wisedu 的 encryptAES 加密密码
///  3. POST 提交表单 → CAS 发 ticket，dio 带 CookieJar 自动跟随 302
///     经 eportal 种会话
///  4. 再访问 appShow 教务入口，服务端 302 给 jw.gdgm.cn 种课表会话
///  5. 从 CookieJar 导出 jw.gdgm.cn 的 Cookie 字符串
class CasLoginService {
  late final CookieJar _jar;
  late final Dio _dio;

  CasLoginService() {
    _jar = CookieJar();
    _dio = Dio(BaseOptions(
      followRedirects: true,
      maxRedirects: 10,
      // 4xx/3xx 都放行，自己判断
      validateStatus: (s) => s != null && s < 500,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
      },
    ));
    _dio.interceptors.add(CookieManager(_jar));
  }

  /// 登录并返回 jw.gdgm.cn 的 Cookie 字符串（形如 "JSESSIONID=xxx; ..."）。
  /// 失败抛 [CasLoginException]。
  Future<String> login(String username, String password) async {
    // 1) 取登录页
    final loginPageResp = await _dio.get<String>(AppConfig.loginPwdUrl);
    final pageHtml = loginPageResp.data ?? '';
    if (pageHtml.isEmpty) {
      throw CasLoginException('无法打开登录页，请检查网络');
    }

    final doc = html_parser.parse(pageHtml);
    final form = doc.querySelector('#casLoginForm') ??
        doc.querySelector('form');
    if (form == null) {
      throw CasLoginException('登录页解析失败');
    }

    // 提取表单所有隐藏字段（lt/execution/_eventId/dllt/rmShown 等）
    final formData = <String, String>{};
    for (final input in form.querySelectorAll('input')) {
      final name = input.attributes['name'];
      if (name == null || name.isEmpty) continue;
      formData[name] = input.attributes['value'] ?? '';
    }

    // 提取加密盐
    final salt = _extractSalt(pageHtml);

    // 若页面强制要求验证码，直接提示走 WebView
    if (pageHtml.contains('id="cpatchaDiv"') &&
        !pageHtml.contains('id="cpatchaDiv" style="display: none;')) {
      throw CasLoginException('需要验证码，请改用网页登录');
    }

    // 2) 加密密码（无盐则明文）
    final encrypted =
        salt.isEmpty ? password : _encryptPassword(password, salt);

    formData['username'] = username;
    formData['password'] = encrypted;

    // 提交地址：优先用表单 action，否则回退配置
    final action = form.attributes['action'];
    final postUrl = (action != null && action.isNotEmpty)
        ? Uri.parse(AppConfig.loginPwdUrl).resolve(action).toString()
        : AppConfig.loginPwdUrl;

    // 3) POST 登录
    final postResp = await _dio.post<String>(
      postUrl,
      data: formData,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {
          'Referer': AppConfig.loginPwdUrl,
          'Origin': 'https://sfrz.gdgm.cn',
        },
      ),
    );

    final respHtml = postResp.data ?? '';
    final finalUrl = postResp.realUri.toString();

    // 仍停在认证域且返回登录表单 → 账号密码错误或需验证码
    final stillOnAuth = finalUrl.contains('sfrz.gdgm.cn/authserver');
    if (stillOnAuth && respHtml.contains('casLoginForm')) {
      throw CasLoginException(_extractError(respHtml));
    }

    // 4) 走教务入口握手（服务端 302 给 jw 种会话）
    await _dio.get<String>(
      AppConfig.jwEntryUrl,
      options: Options(headers: {'Referer': AppConfig.portalUrl}),
    );
    // 兜底再点一次教务主框架，确保拿到 JSESSIONID
    await _dio.get<String>(
      AppConfig.jwMainUrl,
      options: Options(headers: {'Referer': AppConfig.portalUrl}),
    );

    // 5) 导出 jw.gdgm.cn 的 Cookie
    final cookies =
        await _jar.loadForRequest(Uri.parse(AppConfig.jwHost));
    final cookieStr =
        cookies.map((c) => '${c.name}=${c.value}').join('; ');

    if (cookieStr.isEmpty || !cookieStr.contains('JSESSIONID')) {
      throw CasLoginException('登录成功但未取得教务会话，请重试或改用网页登录');
    }
    return cookieStr;
  }

  /// wisedu encryptAES：AES-CBC-PKCS7，key=盐，iv=随机16位，明文=随机64位+密码，输出base64
  String _encryptPassword(String password, String salt) {
    final key = enc.Key.fromUtf8(salt);
    final ivStr = _randomString(16);
    final iv = enc.IV.fromUtf8(ivStr);
    final encrypter = enc.Encrypter(
      enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'),
    );
    final plain = _randomString(64) + password;
    return encrypter.encrypt(plain, iv: iv).base64;
  }

  String _extractSalt(String html) {
    final m = RegExp(r'''pwdDefaultEncryptSalt\s*=\s*["']([^"']+)["']''')
        .firstMatch(html);
    return m?.group(1) ?? '';
  }

  /// 从返回页面提取错误提示（如"用户名或密码错误"）
  String _extractError(String html) {
    final doc = html_parser.parse(html);
    for (final sel in ['#showErrorTip', '.login-error', '#msg', '.errors']) {
      final el = doc.querySelector(sel);
      final t = el?.text.trim() ?? '';
      if (t.isNotEmpty) return t;
    }
    if (html.contains('用户名或密码') || html.contains('密码错误')) {
      return '用户名或密码错误';
    }
    return '登录失败，请检查账号密码';
  }

  static const _chars =
      'ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678';
  final _rand = Random.secure();
  String _randomString(int len) => List.generate(
        len,
        (_) => _chars[_rand.nextInt(_chars.length)],
      ).join();
}
