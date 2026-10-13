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

/// 纯 HTTP 模拟统一身份认证(CAS)登录（不打开网页的备用路径）。
///
/// 关键点一：**手动逐跳跟随 302 重定向**，每跳都过 CookieJar。
/// 若用 dio 的自动 followRedirects，中间跳转的 Set-Cookie 会丢失，
/// 导致 SSO 过程中 eportal/jw 逐跳种的会话 cookie 拿不到。
///
/// 关键点二：**每个请求都必须显式设置 validateStatus**。
/// dio 的默认规则是"只有 2xx 算成功"，而登录全程全是 302；
/// 直接 new 一个 RequestOptions 而不带 validateStatus，就会在第一次
/// 跳转时抛 DioException(bad response, 302)。所以统一走 [_ro] 构造。
class CasLoginService {
  late final CookieJar _jar;
  late final Dio _dio;

  CasLoginService() {
    _jar = CookieJar();
    _dio = Dio(BaseOptions(
      followRedirects: false, // 手动跟跳，保证每跳都过 CookieJar
      validateStatus: _acceptAll,
      connectTimeout: AppConfig.connectTimeout,
      receiveTimeout: AppConfig.receiveTimeout,
      headers: {
        'User-Agent': AppConfig.userAgent,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
    ));
    _dio.interceptors.add(CookieManager(_jar));
  }

  /// 4xx 也可能是正常业务响应（例如密码错误回到登录页），
  /// 只有 5xx 才算真正的服务端故障。
  static bool _acceptAll(int? s) => s != null && s < 500;

  bool debugLog = false;
  final List<String> _trace = [];
  List<String> get trace => List.unmodifiable(_trace);

  /// 统一构造请求参数，确保 followRedirects / validateStatus 不会漏设
  RequestOptions _ro(
    String path, {
    String method = 'GET',
    Map<String, String>? headers,
    Object? data,
    String? contentType,
  }) {
    return RequestOptions(
      path: path,
      method: method,
      data: data,
      contentType: contentType,
      headers: headers ?? const {},
      followRedirects: false,
      validateStatus: _acceptAll,
    );
  }

  /// 登录并返回 jw.gdgm.cn 的 Cookie 字符串。失败抛 [CasLoginException]。
  Future<String> login(String username, String password) async {
    _trace.clear();

    // 1) 取登录页（可能自身也有跳转）
    final pageResp = await _follow(_ro(AppConfig.loginPwdUrl));
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

    // 是否真需要验证码：用 CAS 权威接口判断，而不是猜 HTML
    if (await _needCaptcha(username)) {
      throw CasLoginException('该账号当前需要验证码，请改用网页登录');
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
    final postResp = await _follow(_ro(
      postUrl,
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
    await _follow(_ro(AppConfig.jwEntryUrl,
        headers: {'Referer': AppConfig.portalUrl}));

    // 4) 再访问一次教务主框架，确保 JSESSIONID 落定并验证会话真的有效。
    //    若 SSO 握手没完成，jw 只会给一个"匿名" JSESSIONID：cookie 有、
    //    但一请求就被打回登录页。这里必须确认真的落在了教务主框架。
    final mainResp = await _follow(_ro(AppConfig.jwMainUrl,
        headers: {'Referer': AppConfig.portalUrl}));
    final mainUrl = mainResp.realUri.toString();
    final mainHtml = mainResp.data?.toString() ?? '';
    final bouncedToLogin = mainUrl.contains('authserver') ||
        mainUrl.contains('/login') ||
        mainHtml.contains('casLoginForm') ||
        mainHtml.contains('pwdDefaultEncryptSalt');
    final onJwMain = mainUrl.contains('/jsxsd/') && !bouncedToLogin;

    // 5) 导出 jw.gdgm.cn 的 Cookie
    final cookies = await _jar.loadForRequest(Uri.parse(AppConfig.jwHost));
    final cookieStr =
        cookies.map((c) => '${c.name}=${c.value}').join('; ');

    if (debugLog) {
      debugPrint('=== CAS 登录跳转链 ===');
      for (final t in _trace) {
        debugPrint(t);
      }
      debugPrint('final jw url: $mainUrl (onJwMain=$onJwMain)');
      debugPrint('jw cookies: $cookieStr');
    }

    if (cookieStr.isEmpty || !cookieStr.contains('JSESSIONID')) {
      throw CasLoginException('登录成功但未取得教务会话，请重试或改用网页登录');
    }
    if (!onJwMain) {
      // 有 JSESSIONID 但会话未真正生效（匿名会话），拒绝返回，避免"登进去又被踢"
      throw CasLoginException('教务会话未生效，请重试或改用网页登录');
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
      // 302 后一律 GET，并带上 Referer；同样要显式放开 3xx
      opts = _ro(
        next.toString(),
        headers: {'Referer': resp.realUri.toString()},
      );
      resp = await _dio.fetch(opts);
      _trace.add('GET $next -> ${resp.statusCode}');
    }
    return resp;
  }

  bool _isRedirect(int? s) => s != null && s >= 300 && s < 400;

  /// 查 CAS 是否要求该用户输验证码。接口返回 "true"/"false"。
  /// 出错时保守返回 false（让登录照常尝试，真要验证码时 POST 会报错兜住）。
  Future<bool> _needCaptcha(String username) async {
    try {
      final url =
          'https://sfrz.gdgm.cn/authserver/needCaptcha.html?username=$username'
          '&_=${DateTime.now().millisecondsSinceEpoch}';
      final resp = await _dio.get<String>(
        url,
        options: Options(
          headers: {'Referer': AppConfig.loginPwdUrl},
          followRedirects: false,
          validateStatus: _acceptAll,
        ),
      );
      final t = (resp.data ?? '').trim().toLowerCase();
      _trace.add('needCaptcha -> $t');
      return t.contains('true');
    } catch (_) {
      return false;
    }
  }

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
    if (html.contains('验证码')) {
      return '需要验证码，请改用网页登录';
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
