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

  Future<void> _onUrl(String url) async {
    if (_handled) return;
    // 跳回教务主框架 => 登录成功
    final ok = AppConfig.loginSuccessMarkers.any((m) => url.contains(m));
    if (!ok) return;
    _handled = true;

    // 抓取 jw.gdgm.cn 下的 Cookie
    final cookieManager = CookieManager.instance();
    final cookies = await cookieManager.getCookies(
      url: WebUri(AppConfig.jwHost),
    );
    final cookieStr =
        cookies.map((c) => '${c.name}=${c.value}').join('; ');

    if (cookieStr.isEmpty) {
      _handled = false; // 没抓到，允许重试
      return;
    }

    await AuthStore.saveCookie(cookieStr);
    if (mounted) Navigator.of(context).pop(true);
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
          if (url != null) await _onUrl(url.toString());
        },
        onUpdateVisitedHistory: (c, url, _) async {
          if (url != null) await _onUrl(url.toString());
        },
      ),
    );
  }
}
