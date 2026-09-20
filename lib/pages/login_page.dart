import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../config.dart';
import '../services/auth_store.dart';

/// WebView 登录页：加载教务系统入口，自动跳转到统一身份认证。
/// 用户正常输入账号密码/验证码，登录成功跳回教务主框架后抓取 Cookie。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  InAppWebViewController? _controller;
  double _progress = 0;
  bool _handled = false;

  /// 是否已经历过登录页（SSO / eportal / 认证服务器）。
  /// 只有真正经过登录页后落回主框架，才算登录成功——
  /// 避免刚启动访问主框架被重定向前那一瞬间误判。
  bool _sawLoginPage = false;

  bool _isLoginUrl(String url) {
    final u = url.toLowerCase();
    return u.contains('eportal') ||
        u.contains('authserver') ||
        u.contains('login') ||
        u.contains('cas') ||
        u.contains('sso');
  }

  Future<void> _onUrl(String url, InAppWebViewController c) async {
    if (_handled) return;

    if (_isLoginUrl(url)) {
      _sawLoginPage = true;
      return;
    }

    // 落地页命中主框架特征
    final hitMarker =
        AppConfig.loginSuccessMarkers.any((m) => url.contains(m));
    if (!hitMarker) return;

    // 二次确认：页面里必须有"退出"按钮，说明确实是已登录的主框架，
    // 而不是未登录被重定向的中间状态。
    final loggedIn = await _pageLooksLoggedIn(c);
    if (!loggedIn) {
      // 还没真正登录：如果这是启动时的首次访问，等它跳去登录页即可
      return;
    }

    // 且必须经历过登录页（防止旧会话残留时的误判）
    if (!_sawLoginPage) return;

    _handled = true;

    final cookieManager = CookieManager.instance();
    final cookies = await cookieManager.getCookies(
      url: WebUri(AppConfig.jwHost),
    );
    final cookieStr =
        cookies.map((ck) => '${ck.name}=${ck.value}').join('; ');

    if (cookieStr.isEmpty) {
      _handled = false;
      return;
    }

    await AuthStore.saveCookie(cookieStr);
    if (mounted) Navigator.of(context).pop(true);
  }

  /// 用 JS 检查页面是否包含已登录标志（退出按钮 / 消息通知）
  Future<bool> _pageLooksLoggedIn(InAppWebViewController c) async {
    try {
      final r = await c.evaluateJavascript(source: '''
        (function(){
          var t = document.body ? document.body.innerText : '';
          return (t.indexOf('退出') >= 0 || t.indexOf('消息通知') >= 0) ? '1' : '0';
        })()
      ''');
      return r?.toString() == '1';
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录教务系统'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller?.reload(),
          ),
        ],
        bottom: _progress < 1.0
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(value: _progress),
              )
            : null,
      ),
      body: InAppWebView(
        initialUrlRequest:
            URLRequest(url: WebUri(AppConfig.loginStartUrl)),
        initialSettings: InAppWebViewSettings(
          userAgent:
              'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
          javaScriptEnabled: true,
          thirdPartyCookiesEnabled: true,
          sharedCookiesEnabled: true,
        ),
        onWebViewCreated: (c) => _controller = c,
        onProgressChanged: (c, p) {
          setState(() => _progress = p / 100);
        },
        onLoadStop: (c, url) async {
          if (url != null) await _onUrl(url.toString(), c);
        },
        onUpdateVisitedHistory: (c, url, _) async {
          if (url != null) await _onUrl(url.toString(), c);
        },
      ),
    );
  }
}
