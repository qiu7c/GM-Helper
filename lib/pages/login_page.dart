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

/// 登录分为两个阶段：
/// 阶段1 - 在统一身份认证(sfrz/authserver)页输账号密码，成功后落到 eportal 门户首页；
/// 阶段2 - 用同一 WebView（已持有 SSO Cookie）跳转教务系统入口，
///        CAS 自动放行并给教务系统种下会话，然后抓取教务 Cookie。
enum _Phase { portalLogin, jwHandshake, done }

class _LoginPageState extends State<LoginPage> {
  InAppWebViewController? _controller;
  double _progress = 0;
  _Phase _phase = _Phase.portalLogin;
  String _hint = '请登录统一身份认证';

  Future<void> _onUrl(String url, InAppWebViewController c) async {
    if (_phase == _Phase.done) return;

    // 阶段1：门户登录成功（落到 eportal 首页）→ 切换去教务系统握手
    if (_phase == _Phase.portalLogin) {
      final portalOk =
          AppConfig.portalSuccessMarkers.any((m) => url.contains(m));
      if (portalOk) {
        _phase = _Phase.jwHandshake;
        setState(() => _hint = '正在进入教务系统…');
        await c.loadUrl(
          urlRequest: URLRequest(url: WebUri(AppConfig.jwEntryUrl)),
        );
      }
      return;
    }

    // 阶段2：进入教务主框架
    if (_phase == _Phase.jwHandshake) {
      final jwOk =
          AppConfig.loginSuccessMarkers.any((m) => url.contains(m));
      if (!jwOk) return;

      // 确认是已登录的主框架（有"退出/消息通知"字样）
      final loggedIn = await _pageLooksLoggedIn(c);
      if (!loggedIn) return;

      final cookieManager = CookieManager.instance();
      final cookies = await cookieManager.getCookies(
        url: WebUri(AppConfig.jwHost),
      );
      final cookieStr =
          cookies.map((ck) => '${ck.name}=${ck.value}').join('; ');

      if (cookieStr.isEmpty) return; // 还没种上，等下一次事件

      _phase = _Phase.done;
      await AuthStore.saveCookie(cookieStr);
      if (mounted) Navigator.of(context).pop(true);
    }
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
        title: Text(_hint),
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
          // ↓↓ 修黑屏的关键设置 ↓↓
          // Android 用混合合成，解决部分机型 WebView 全黑不渲染
          useHybridComposition: true,
          // 教务/门户偶有 http 资源，允许混合内容，否则页面部分空白
          mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
          // 支持缩放，页面太宽时可放大看清
          supportZoom: true,
          builtInZoomControls: true,
          displayZoomControls: false,
          useWideViewPort: true,
          loadWithOverviewMode: true,
          // iOS 允许内联播放，避免白/黑屏
          allowsInlineMediaPlayback: true,
          transparentBackground: false,
        ),
        onWebViewCreated: (c) => _controller = c,
        onProgressChanged: (c, p) {
          setState(() => _progress = p / 100);
        },
        onReceivedError: (c, req, err) {
          // 打印错误便于排查（如证书、网络）
          debugPrint('WebView error: ${err.type} ${err.description}');
        },
        onReceivedHttpError: (c, req, resp) {
          debugPrint('WebView http error: ${resp.statusCode}');
        },
        // 忽略自签名/证书告警，避免因证书问题导致空白
        onReceivedServerTrustAuthRequest: (c, challenge) async {
          return ServerTrustAuthResponse(
            action: ServerTrustAuthResponseAction.PROCEED,
          );
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
