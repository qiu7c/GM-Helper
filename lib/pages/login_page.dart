import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../config.dart';
import '../services/auth_store.dart';

/// 登录页：驱动系统 WebView 完成统一身份认证(CAS)登录。
///
/// 传了 [autoUsername] / [autoPassword] 时进入**自动填充**模式：
/// 把账号密码写进登录页的两个输入框，再点它自己的登录按钮 ——
/// 等价于"模拟人手动输入再提交"。密码加密、302 跳转、Cookie 种下
/// 全部由浏览器内核完成，比用 Dart 重写一套 CAS 可靠得多。
///
/// 页面保持可见可交互：万一跳出验证码，用户直接在网页上输入即可接管。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.autoUsername, this.autoPassword});

  final String? autoUsername;
  final String? autoPassword;

  bool get auto =>
      (autoUsername ?? '').isNotEmpty && (autoPassword ?? '').isNotEmpty;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

/// 登录分两个阶段：
/// 阶段1 - 在统一身份认证(sfrz/authserver)页输账号密码，成功后落到 eportal 门户首页；
/// 阶段2 - 用同一 WebView（已持有 SSO Cookie）跳转教务系统入口，
///        CAS 自动放行并给教务系统种下会话，然后抓取教务 Cookie。
enum _Phase { login, jwHandshake, done }

class _LoginPageState extends State<LoginPage> {
  InAppWebViewController? _controller;
  double _progress = 0;
  _Phase _phase = _Phase.login;
  String _hint = '请登录统一身份认证';

  /// 用户选择的登录方式对应的起始地址；为 null 时显示登录方式选择界面
  String? _startUrl;

  /// 自动填充是否已经提交过（只提交一次，避免密码错了被反复重试锁号）
  bool _autoSubmitted = false;

  /// 自动填充尝试次数（页面可能还没渲染完，需要重试几次）
  int _autoTries = 0;

  /// 防止 onLoadStop / onUpdateVisitedHistory 并发触发放大点击
  bool _autoBusy = false;

  /// 登录页回显的错误（账号密码错、需要验证码等）
  String? _pageError;

  /// 自动填充时两个输入框的实际长度（如 "账号10/密码8"），用于排错
  String _fillState = '';

  @override
  void initState() {
    super.initState();
    if (widget.auto) {
      _startUrl = AppConfig.loginPwdUrl;
      _hint = '正在自动登录…';
    }
  }

  Future<void> _onUrl(String url, InAppWebViewController c) async {
    if (_phase == _Phase.done) return;

    // 阶段1：统一身份认证页
    if (_phase == _Phase.login) {
      // 门户登录成功（落到 eportal 首页）→ 切换去教务系统握手
      if (AppConfig.portalSuccessMarkers.any((m) => url.contains(m))) {
        _phase = _Phase.jwHandshake;
        if (mounted) setState(() => _hint = '正在进入教务系统…');
        await c.loadUrl(
          urlRequest: URLRequest(url: WebUri(AppConfig.jwEntryUrl)),
        );
        return;
      }
      // 自动填充模式：在 CAS 登录页把账号密码填进去并点登录
      if (widget.auto && url.contains('/authserver/login')) {
        if (_autoSubmitted) {
          await _readPageError(c); // 已经交过一次，这回是回显的错误
        } else {
          await _autoFill(c);
        }
      }
      return;
    }

    // 阶段2：教务主框架。
    // 能落到 xsMain.jsp 就说明 CAS 已放行、jw 会话已建立
    //（未登录会被 CAS 打回登录页，根本到不了这里）。
    // 注意：xsMain.jsp 是 frameset，顶层 document 没有正文，
    // 不能靠"退出/消息通知"字样判断——那会一直判为未登录，导致 cookie 存不上。
    if (_phase == _Phase.jwHandshake) {
      if (!_isJwAppUrl(url)) return;

      final cookieStr = await _collectJwCookies();
      // 必须拿到 jw 的会话票据(JSESSIONID)才算成功，否则等下一次事件
      if (!cookieStr.contains('JSESSIONID')) return;

      _phase = _Phase.done;
      await AuthStore.saveCookie(cookieStr);
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  /// 判断是否已经进入教务系统内部（而非登录/跳转页）
  bool _isJwAppUrl(String url) {
    if (AppConfig.loginSuccessMarkers.any((m) => url.contains(m))) return true;
    return url.contains('/jsxsd/') && !url.contains('login');
  }

  /// 往登录页的两个输入框写入账号密码，然后点它自己的登录按钮。
  ///
  /// 两个坑：
  ///  1. 必须**点按钮**而不是 form.submit()，因为密码加密是在按钮的点击
  ///     处理器里做的，直接提交会把明文发过去。
  ///  2. 不少登录页会清空密码框（防自动填充），或者给密码框加 readonly。
  ///     所以填完要**当场回读校验**，两格都有值才提交；否则不提交，稍后重试，
  ///     免得拿空密码去撞把账号锁了。
  Future<void> _autoFill(InAppWebViewController c) async {
    if (_autoSubmitted || _autoBusy) return;
    // 重试到头仍没填进去：明确告诉用户手动接管，别让他干等
    if (_autoTries > 8) {
      if (mounted && _phase == _Phase.login && _pageError == null) {
        setState(() => _pageError = '自动填写没生效（$_fillState），'
            '请在页面上手动输入密码后点「登录」。');
      }
      return;
    }
    _autoBusy = true;
    _autoTries++;
    try {
      final user = jsonEncode(widget.autoUsername);
      final pass = jsonEncode(widget.autoPassword);
      final result = (await c.evaluateJavascript(source: '''
        (function () {
          var u = document.querySelector('#username')
               || document.querySelector('input[name="username"]');
          var p = document.querySelector('#password')
               || document.querySelector('input[name="password"]');
          if (!u || !p) return 'NOFORM';

          function setVal(el, v) {
            try { el.removeAttribute('readonly'); } catch (e) {}
            try { el.focus(); } catch (e) {}
            try {
              var d = Object.getOwnPropertyDescriptor(
                  el.constructor.prototype, 'value');
              if (d && d.set) { d.set.call(el, v); } else { el.value = v; }
            } catch (e) { el.value = v; }
            if (el.value !== v) {
              try { el.setAttribute('value', v); } catch (e) {}
            }
            // 只发 input/change。不要发 blur：有些登录页在失焦时会清空密码框。
            el.dispatchEvent(new Event('input',  { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return el.value === v;
          }

          var okU = setVal(u, $user);
          var okP = setVal(p, $pass);
          // 被清掉就同步再写一次（不给页面的定时器留机会）
          if (!okP) { okP = setVal(p, $pass); }
          if (!okU) { okU = setVal(u, $user); }

          var state = '账号' + (u.value ? u.value.length : 0) +
                      '/密码' + (p.value ? p.value.length : 0);
          if (!okP || !u.value || !p.value) return 'PWDFAIL:' + state;

          var btn = document.querySelector('#loginButton')
                 || document.querySelector('#submitBtn')
                 || document.querySelector('button[type="submit"]')
                 || document.querySelector('input[type="submit"]');
          if (!btn) return 'NOBTN:' + state;

          btn.click();
          return 'CLICKED:' + state;
        })()
      '''))?.toString() ??
          '';

      if (result.startsWith('CLICKED')) {
        _autoSubmitted = true;
        if (mounted) {
          setState(() {
            _fillState = result.substring('CLICKED:'.length);
            _hint = '正在登录…';
          });
        }
        _watchStuck();
        return;
      }

      // 没提交成功（页面没渲染完 / 密码被清空 / 找不到按钮）：稍后重试
      if (result.startsWith('PWDFAIL')) {
        _fillState = result.substring('PWDFAIL:'.length);
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted || _phase != _Phase.login || _autoSubmitted) return;
      _autoBusy = false;
      await _autoFill(c);
      return;
    } catch (_) {
      // 注入失败就交给用户手动在页面上操作
    } finally {
      _autoBusy = false;
    }
  }

  /// 点了登录但迟迟没跳转时，提示用户手动接管
  Future<void> _watchStuck() async {
    await Future<void>.delayed(const Duration(seconds: 6));
    if (!mounted || _phase != _Phase.login) return;
    setState(() => _hint = '若没反应，请手动点页面上的「登录」');
  }

  /// 读登录页上的错误提示（账号密码错 / 需要验证码）
  Future<void> _readPageError(InAppWebViewController c) async {
    try {
      final err = (await c.evaluateJavascript(source: '''
        (function () {
          var sels = ['#showErrorTip', '.login-error', '#msg', '.errors', '#errorMsg'];
          for (var i = 0; i < sels.length; i++) {
            var e = document.querySelector(sels[i]);
            if (e && e.innerText && e.innerText.trim()) return e.innerText.trim();
          }
          var t = document.body ? document.body.innerText : '';
          if (t.indexOf('验证码') >= 0) return '需要验证码，请在页面上输入验证码后点登录';
          if (t.indexOf('密码') >= 0 && t.indexOf('错误') >= 0) return '用户名或密码错误';
          return '';
        })()
      '''))?.toString();
      if (err != null && err.isNotEmpty && err != _pageError) {
        setState(() {
          _pageError = err;
          _hint = '登录失败，请手动处理';
        });
      }
    } catch (_) {}
  }

  /// 取 jw.gdgm.cn 下所有 Cookie。
  /// 要按多个具体路径分别查：JSESSIONID 的 Path 可能是 /jsxsd 而不是 /，
  /// 只查域名根路径会漏掉它，导致"网页明明登进去了却抓不到会话"。
  Future<String> _collectJwCookies() async {
    final cm = CookieManager.instance();
    final urls = <String>[
      AppConfig.jwHost,
      '${AppConfig.jwHost}/jsxsd/',
      '${AppConfig.jwHost}/jsxsd/framework/xsMain.jsp',
      '${AppConfig.jwHost}/jsxsd/xskb/xskb_list.do',
    ];
    final merged = <String, String>{}; // name -> value（后者覆盖前者）
    for (final u in urls) {
      try {
        final list = await cm.getCookies(url: WebUri(u));
        for (final ck in list) {
          if (ck.name.isNotEmpty) merged[ck.name] = ck.value;
        }
      } catch (_) {}
    }
    return merged.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 登录方式选择界面
  Widget _buildMethodPicker() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset('assets/icon/app_logo.png', width: 80, height: 80),
          const SizedBox(height: 12),
          const Text('GMPluse',
              style:
                  TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('请选择登录方式',
              style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.password),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('账号密码登录', style: TextStyle(fontSize: 16)),
              ),
              onPressed: () =>
                  setState(() => _startUrl = AppConfig.loginPwdUrl),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.qr_code_2),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('企业微信扫码登录', style: TextStyle(fontSize: 16)),
              ),
              onPressed: () =>
                  setState(() => _startUrl = AppConfig.loginQrUrl),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 未选择登录方式：先展示选择界面
    if (_startUrl == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('选择登录方式')),
        body: _buildMethodPicker(),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_hint),
        actions: [
          if (!widget.auto)
            IconButton(
              tooltip: '换登录方式',
              icon: const Icon(Icons.swap_horiz),
              onPressed: () {
                setState(() {
                  _startUrl = null;
                  _phase = _Phase.login;
                  _hint = '请登录统一身份认证';
                });
              },
            ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller?.reload(),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _progress < 1.0
              ? LinearProgressIndicator(value: _progress)
              : const SizedBox(height: 3),
        ),
      ),
      body: Column(
        children: [
          if (_pageError != null)
            Container(
              width: double.infinity,
              color: Colors.redAccent.withOpacity(0.12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.error_outline,
                      size: 18, color: Colors.redAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_pageError!,
                        style: const TextStyle(
                            fontSize: 13, color: Colors.redAccent)),
                  ),
                ],
              ),
            )
          else if (widget.auto)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                _autoSubmitted
                    ? '已自动填入（$_fillState）并提交；若出现验证码，请在页面上输入后点「登录」。'
                    : '正在自动填入账号密码…',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          Expanded(
            child: InAppWebView(
              key: ValueKey(_startUrl),
              initialUrlRequest: URLRequest(url: WebUri(_startUrl!)),
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
          ),
        ],
      ),
    );
  }
}
