import 'dart:math';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
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
/// 关键点：**手动逐跳跟随 302 重定向**，每跳都过 CookieJar。
/// 若用 dio 的自动 followRedirects，中间跳转的 Set-Cookie 会丢失，
/// 导致 SSO 过程中 eportal/jw 逐跳种的会话 cookie 拿不到。
class CasLoginService {
  late final CookieJar _jar;
  late final Dio _dio;

  CasLoginService() {
    _jar = CookieJar();
    _dio = Dio(BaseOptions(
      followRedirects: false, // 手动跟跳，保证每跳都过 CookieJar
      validateStatus: (s) => s != null && s < 500,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
    ));
    _dio.interceptors.add(CookieManager(_jar));
  }

  bool debugLog = false;
  final List<String> _trace = [];
  List<String> get trace => List.unmodifiable(_trace);

  /// 登录并返回 jw.gdgm.cn 的 Cookie 字符串。失败抛 [CasLoginException]。
  Future<String> login(String username, String password) async {
    _trace.clear();

    // 1) 取登录页（可能自身也有跳转）
    final pageResp = await _follow(RequestOptions(
      path: AppConfig.loginPwdUrl,
      method: 'GET',
    ));
    final pageHtml = pageResp.data?.toString() ?? '';
    if (pageHtml.isEmpty) {
      throw CasLoginException('无法打开登录页，请检查网络');
    }

    final doc = html_parser.parse(pageHtml);
    final form =
        doc.querySelector('#casLoginForm') ?? doc.querySelector('form');
    if (form == null) throw CasLoginException('登录页解析失败');

    // 隐藏字段：lt / execution / _eventId / dllt / rmShown ...
    final formData = <String, String>{};
    for (final input in form.querySelectorAll('input')) {
      final name = input.attributes['name'];
      if (name == null || name.isEmpty) continue;
      formData[name] = input.attributes['value'] ?? '';
    }

    // 验证码强制出现则提示走 WebView
    if (pageHtml.contains('id="cpatchaDiv"') &&
        !pageHtml.contains('id="cpatchaDiv" style="display: none;"')) {
      throw CasLoginException('需要验证码，请改用网页登录');
    }

    final salt = _extractSalt(pageHtml);
    formData['username'] = username;
    formData['password'] =
        salt.isEmpty ? password : _encryptPassword(password, salt);

    final action = form.attributes['action'];
    final postUrl = (action != null && action.isNotEmpty)
        ? pageResp.realUri.resolve(action).toString()
        : AppConfig.loginPwdUrl;

    // 2) POST 登录，并逐跳跟随其后的 302 链（经 eportal 种会话）
    final postResp = await _follow(RequestOptions(
      path: postUrl,
      method: 'POST',
      data: _encodeForm(formData),
      contentType: Headers.formUrlEncodedContentType,
      headers: {
        'Referer': AppConfig.loginPwdUrl,
        'Origin': 'https://sfrz.gdgm.cn',
      },
    ));

    final finalUrl = postResp.realUri.toString();
    final respHtml = postResp.data?.toString() ?? '';
    if (finalUrl.contains('sfrz.gdgm.cn/authserver') &&
        respHtml.contains('casLoginForm')) {
      throw CasLoginException(_extractError(respHtml));
    }

    // 3) 走教务入口 appShow，逐跳跟到 jw，给 jw 种会话
    await _follow(RequestOptions(
      path: AppConfig.jwEntryUrl,
      method: 'GET',
      headers: {'Referer': AppConfig.portalUrl},
    ));

    // 4) 再访问一次教务主框架，确保 JSESSIONID 落定
    await _follow(RequestOptions(
      path: AppConfig.jwMainUrl,
      method: 'GET',
      headers: {'Referer': AppConfig.portalUrl},
    ));

    // 5) 导出 jw.gdgm.cn 的 Cookie
    final cookies = await _jar.loadForRequest(Uri.parse(AppConfig.jwHost));
    final cookieStr =
        cookies.map((c) => '${c.name}=${c.value}').join('; ');

    if (debugLog) {
      debugPrint('=== CAS 登录跳转链 ===');
      for (final t in _trace) {
        debugPrint(t);
      }
      debugPrint('jw cookies: $cookieStr');
    }

    if (cookieStr.isEmpty || !cookieStr.contains('JSESSIONID')) {
      throw CasLoginException('登录成功但未取得教务会话，请重试或改用网页登录');
    }
    return cookieStr;
  }

  /// 手动逐跳跟随重定向。每跳请求都经过 CookieManager 拦截器，
  /// 因此中途 Set-Cookie 会被正确存入 CookieJar，也会带上已有 cookie。
  Future<Response> _follow(RequestOptions options, {int max = 15}) async {
    var opts = options;
    Response resp = await _dio.fetch(opts);
    _trace.add('${opts.method} ${opts.path} -> ${resp.statusCode}');

    var hops = 0;
    while (_isRedirect(resp.statusCode) && hops < max) {
      final loc = resp.headers.value('location');
      if (loc == null || loc.isEmpty) break;
      final next = resp.realUri.resolve(loc);
      hops++;
      opts = RequestOptions(
        path: next.toString(),
        method: 'GET', // 302 后一律 GET
        headers: {'Referer': resp.realUri.toString()},
        followRedirects: false,
        validateStatus: (s) => s != null && s < 500,
      );
      resp = await _dio.fetch(opts);
      _trace.add('GET $next -> ${resp.statusCode}');
    }
    return resp;
  }

  bool _isRedirect(int? s) => s != null && s >= 300 && s < 400;

  String _encodeForm(Map<String, String> data) => data.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  /// wisedu encryptAES：AES-CBC-PKCS7，key=盐，iv=随机16位，明文=随机64位+密码，base64
  String _encryptPassword(String password, String salt) {
    final key = enc.Key.fromUtf8(salt);
    final iv = enc.IV.fromUtf8(_randomString(16));
    final encrypter = enc.Encrypter(
      enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'),
    );
    return encrypter.encrypt(_randomString(64) + password, iv: iv).base64;
  }

  String _extractSalt(String html) {
    final m = RegExp(r'''pwdDefaultEncryptSalt\s*=\s*["']([^"']+)["']''')
        .firstMatch(html);
    return m?.group(1) ?? '';
  }

  String _extractError(String html) {
    final doc = html_parser.parse(html);
    for (final sel in ['#showErrorTip', '.login-error', '#msg', '.errors']) {
      final t = doc.querySelector(sel)?.text.trim() ?? '';
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
