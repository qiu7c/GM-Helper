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
/// 自动模式下网页默认是**被盖住**的，只显示一个"正在登录"的框。什么情况下
/// 才把网页露出来，这里分得很细：
///
///  - **账号密码错**（`<div class="bh-alert-box">您提供的用户名或者密码有误`）：
///    这是确定的失败，看网页也没用 —— 直接带着原因退回自绘登录页让用户重输。
///  - **要验证码**（同一个 `bh-alert-box`，这时它说的是「请输入验证码」）：
///    只有网页上才能做，必须把网页露出来。
///  - 自动填充对不上页面结构 / 点了登录迟迟不跳 / 整链超时：露出来让用户接管。
///
/// 这个登录页的两个脾气，代码里到处都在迁就：
///  1. 它是"点了提交才有反应"的老式表单 —— 错误提示、要不要验证码，都得 POST
///     一次才吐出来。所以填完必须**点按钮**，不能指望页面提前给信号。
///  2. 但**验证码控件本身是提交前就在页面上的**，所以提交前能先看见它、提前让位；
///     否则每次都要拿一次注定失败的提交去换那句"请输入验证码"，白费尝试。
///  3. 密码错的提示和验证码的提示共用 `bh-alert-box` 这一个元素，只能按**文字**
///     区分，不能按选择器区分；两者同时出现时（密码错很多次之后就是这样）
///     按验证码处理 —— 那时候密码和验证码都得在网页上改。
///
/// 把网页藏起来用的是 **Opacity(0)**，不是 Offstage / 尺寸 0 —— 后两者会让
/// WebView 失去真实布局，`getBoundingClientRect` 返回 0，自动填充直接失效
/// （v1.0.4 就是这么坏的）。Opacity 只影响绘制不影响布局，JS 照跑。
/// 另外它比"盖一层"更彻底：Android 上 WebView 是系统合成的 platform view，
/// 只靠 Flutter 组件盖住，偶尔会漏出一帧。
///
/// 三种进法：[autoUsername]+[autoPassword] 自动登录（网页透明+转圈框）、
/// [initialUrl] 直达某个入口（企业微信扫码，网页全程可见）、
/// 都不给则先出"选择登录方式"。
class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    this.autoUsername,
    this.autoPassword,
    this.initialUrl,
  });

  final String? autoUsername;
  final String? autoPassword;

  /// 跳过"选择登录方式"直接进某个入口（目前用于企业微信扫码）。
  /// 和 [autoUsername] 互斥：扫码没有账号密码可填。
  final String? initialUrl;

  bool get auto =>
      (autoUsername ?? '').isNotEmpty && (autoPassword ?? '').isNotEmpty;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

/// 登录页的返回结果。
///
/// [ok] 为 true 表示登录成功；否则 [message] 非空时是失败原因（账号密码错等），
/// 为空表示用户自己按了返回。
class LoginResult {
  final bool ok;
  final String? message;

  const LoginResult.success()
      : ok = true,
        message = null;
  const LoginResult.failed(this.message) : ok = false;
  const LoginResult.cancelled()
      : ok = false,
        message = null;
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

  /// 登录页里相关输入框的真实结构（自动填充失败时回显，便于定位问题）
  String _domDump = '';

  /// 自动模式下网页是否已经露出来。初始为 false（只显示"正在登录"的框），
  /// 一旦自动登录没成功就置为 true，让用户能在网页上手动接管。
  bool _webVisible = false;

  /// 静默阶段：自动登录正在跑，而且还没到"必须让用户看见"的地步。
  ///
  /// 这时候**整页什么都没有** —— 路由是透明的（见 [AutoLogin.attempt]），
  /// 用户看到的是下面那一页（课表）自己的加载状态，而不是一个"正在登录"的
  /// 界面。自动填充仍然照跑：WebView 有真实布局，只是不画出来。
  ///
  /// 另外两条路（扫码 [initialUrl]、选择登录方式）本来就要用户看着网页操作，
  /// 一进来就是可见的，不走这里。
  bool get _silent => widget.auto && !_webVisible;

  /// 最近一次拿到的页面地址，用来判断"点了登录却还停在认证页"
  String _lastUrl = '';

  /// 已经带着结果退出这一页了，避免收尾阶段被重复 pop
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    if (widget.auto) {
      _startUrl = AppConfig.loginPwdUrl;
      _hint = '正在自动登录…';
      _watchOverall();
    } else if (widget.initialUrl != null) {
      _startUrl = widget.initialUrl;
      _hint = '企业微信扫码登录';
      // 扫码这条路必须**一开始就把网页露出来**：二维码总得让人看见才能扫。
      // 也正因如此这里不调 _watchOverall —— 那个兜底是给"盖着转圈"用的。
      _webVisible = true;
    }
  }

  /// 撤掉遮罩，把网页交还给用户（重复调用无副作用）
  void _reveal({String? hint}) {
    if (!mounted) return;
    if (_webVisible && (hint == null || hint == _hint)) return;
    setState(() {
      _webVisible = true;
      if (hint != null) _hint = hint;
    });
  }

  /// 账号密码错：看网页也没用，直接带着原因退回自绘登录页，让用户重输。
  /// 这样"自绘界面 → 转圈 → 密码错了回到自绘界面"是闭环的，全程看不到网页。
  void _failToSelfDrawn(String message) {
    if (_popped || !mounted) return;
    _popped = true;
    Navigator.of(context).pop<LoginResult>(LoginResult.failed(message));
  }

  /// 兜底：整条自动登录链路超时还没走完，就把网页露出来，别让用户对着转圈干等
  Future<void> _watchOverall() async {
    await Future<void>.delayed(const Duration(seconds: 25));
    if (!mounted || _popped || _phase == _Phase.done || _webVisible) return;
    _reveal(hint: '自动登录超时，请在此页面手动登录');
  }

  Future<void> _onUrl(String url, InAppWebViewController c) async {
    if (_phase == _Phase.done || _popped) return;
    _lastUrl = url;

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
      if (!mounted || _popped) return;
      _popped = true;
      Navigator.of(context).pop<LoginResult>(const LoginResult.success());
    }
  }

  /// 判断是否已经进入教务系统内部（而非登录/跳转页）
  bool _isJwAppUrl(String url) {
    if (AppConfig.loginSuccessMarkers.any((m) => url.contains(m))) return true;
    return url.contains('/jsxsd/') && !url.contains('login');
  }

  /// 往登录页的两个输入框写入账号密码，然后点它自己的登录按钮。
  ///
  /// 三个坑：
  ///  1. 必须**点按钮**而不是 form.submit()，因为密码加密是在按钮的点击
  ///     处理器里做的，直接提交会把明文发过去。
  ///  2. 页面上可能有多个 id/name 叫 password 的元素（含隐藏的），
  ///     必须挑**可见且可用**的那个，否则写进了隐藏框、看着还是空的。
  ///  3. 有些页面在 input 事件里就把密码清掉（反自动填充）——
  ///     所以先**不发任何事件**只写值，页面的提交处理器本来就是直接读
  ///     .value，不需要事件；写不进去才补发 input/change 再试。
  ///
  /// 填完当场回读校验，两格都有值才提交；否则不提交、稍后重试，
  /// 免得拿空密码反复提交把账号锁了。
  Future<void> _autoFill(InAppWebViewController c) async {
    if (_autoSubmitted || _autoBusy || _popped) return;
    // 重试到头仍没填进去：把网页露出来让用户自己输，别让他对着加载框干等
    if (_autoTries > 8) {
      if (mounted && _phase == _Phase.login && _pageError == null) {
        setState(() => _pageError = '自动填写没生效（$_fillState），'
            '请在页面上手动输入密码后点「登录」。');
        _reveal(hint: '请手动登录');
      }
      return;
    }
    _autoBusy = true;
    _autoTries++;
    try {
      final user = jsonEncode(widget.autoUsername);
      final pass = jsonEncode(widget.autoPassword);
      final raw = (await c.evaluateJavascript(source: '''
        (function () {
          function isVisible(el) {
            if (!el || el.disabled) return false;
            var r = el.getBoundingClientRect();
            if (!r || r.width <= 0 || r.height <= 0) return false;
            var s = window.getComputedStyle(el);
            if (!s || s.display === 'none' || s.visibility === 'hidden') return false;
            return true;
          }
          function desc(el) {
            if (!el) return 'null';
            return el.tagName.toLowerCase()
              + ' #' + (el.id || '-')
              + ' name=' + (el.getAttribute('name') || '-')
              + ' type=' + (el.getAttribute('type') || '-')
              + ' vis=' + (isVisible(el) ? '1' : '0')
              + ' dis=' + (el.disabled ? '1' : '0')
              + ' ro=' + (el.readOnly ? '1' : '0');
          }

          // 只看登录表单内部，避免误伤页面上其它表单
          var form = document.querySelector('#casLoginForm')
                  || document.querySelector('form');
          var scope = form || document;
          var all = scope.querySelectorAll('input');

          // 诊断用：把和登录相关的输入框原样报回去（整个文档，不限表单内）
          var dump = [];
          var dumpInputs = document.querySelectorAll('input');
          for (var i = 0; i < dumpInputs.length; i++) {
            var e = dumpInputs[i];
            var t = (e.getAttribute('type') || 'text').toLowerCase();
            var idn = (e.id || '') + ' ' + (e.getAttribute('name') || '');
            if (t === 'password' || t === 'text' || t === 'email' || t === 'tel'
                || /pass|pwd|user|account|login|encrypt|mobile|phone/i.test(idn)) {
              dump.push(desc(e));
            }
          }

          // 用户名：表单内可见的优先，没有可见的才退回第一个
          function pick(match) {
            var fallback = null;
            for (var i = 0; i < all.length; i++) {
              if (!match(all[i])) continue;
              if (isVisible(all[i])) return all[i];
              if (!fallback) fallback = all[i];
            }
            return fallback;
          }
          var u = pick(function (e) {
            return e.id === 'username' || e.getAttribute('name') === 'username';
          });

          // 密码：这个页面把「看得见的输入框」和「真正提交的隐藏框」分开了 ——
          //   #mobilePassword         type=password，看得见，没有 name，不参与提交
          //   #mobilePasswordEncrypt  name=password，display:none，提交的是它，
          //                           值由页面的加密逻辑用 pwdDefaultEncryptSalt 算出
          // 所以只写看得见的那个，再补发页面自己的事件让加密跑起来；
          // 绝不能往隐藏的加密框里写明文，那会把正确的密文覆盖掉。
          function isPwd(el) {
            var t = (el.getAttribute('type') || '').toLowerCase();
            return t === 'password' || el.id === 'password'
                || el.getAttribute('name') === 'password';
          }
          var enc = document.querySelector('input[name="password"]'); // 隐藏的密文框
          if (enc && isVisible(enc)) enc = null; // 真看得见就不是密文框
          var pwds = [];
          for (var i = 0; i < dumpInputs.length; i++) {
            if (dumpInputs[i] !== enc && isPwd(dumpInputs[i])) pwds.push(dumpInputs[i]);
          }
          var pv = null;
          for (var i = 0; i < pwds.length; i++) {
            if (isVisible(pwds[i])) { pv = pwds[i]; break; }
          }

          function write(el, v, doFocus) {
            try { el.readOnly = false; el.removeAttribute('readonly'); } catch (e) {}
            if (doFocus !== false) { try { el.focus(); } catch (e) {} }
            try {
              var d = Object.getOwnPropertyDescriptor(
                  el.constructor.prototype, 'value');
              if (d && d.set) { d.set.call(el, v); } else { el.value = v; }
            } catch (e) { el.value = v; }
            if (el.value !== v) {
              try { el.setAttribute('value', v); } catch (e) {}
            }
            return el.value === v;
          }
          // 只写值，不发事件（屏幕上立刻显示出来，不惊动页面的监听）
          function quiet(el, v, doFocus) { return write(el, v, doFocus); }
          // 写值并补发 input/change（给需要事件的框架用）
          function noisy(el, v, doFocus) {
            write(el, v, doFocus);
            el.dispatchEvent(new Event('input',  { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return el.value === v;
          }
          // 只补发事件、不写值（触发页面自己的逻辑，比如把密码加密进隐藏框）
          function fire(el, type) {
            try { el.dispatchEvent(new Event(type, { bubbles: true })); } catch (e) {}
          }

          var st = 'OK';
          var state = '';
          if (!u || !pv) {
            st = 'NOFORM';
          } else {
            // 用户名：写值 + 发事件，和人手动输入的效果一致
            noisy(u, $user);
            // 密码：先静默写（屏幕上直接出现），验证确实写进去了
            var okP = quiet(pv, $pass);
            if (!okP) okP = noisy(pv, $pass);
            // 补发页面自己的事件，让它的加密逻辑把密文写进隐藏框
            fire(pv, 'input'); fire(pv, 'change'); fire(pv, 'keyup');
            if (enc && !enc.value) fire(pv, 'blur');
            // 有的页面会在失焦后清空明文（防明文残留）。提交前重新查一遍，把看得见的
            // 那个再补一次：既让用户看得见，也让"提交时现读现加密"的页面拿得到密码。
            // 这次不再抢焦点（避免反复弹出软键盘）。
            var fresh = document.querySelectorAll('input');
            for (var k = 0; k < fresh.length; k++) {
              var fe = fresh[k];
              if (fe === enc || !isPwd(fe) || !isVisible(fe)) continue;
              if (fe.value !== $pass) okP = quiet(fe, $pass, false) || okP;
              pv = fe;
              break;
            }
            // 密文长度是个关键线索：0 说明页面的加密还没跑（它会在提交时现算）
            state = '账号' + (u.value ? u.value.length : 0)
                  + '/密码' + (pv.value ? pv.value.length : 0)
                  + '/密文' + (enc ? (enc.value ? enc.value.length : 0) : -1);
            // 提交前先看页面上有没有验证码。
            // 这个登录页是"点了提交才有反应"的老式表单 —— 错误提示、要不要
            // 验证码，都得 POST 一次才知道。但验证码控件本身是**提交前**就
            // 摆在页面上的，所以能提前看见：有就别提交了，那次必然不过，
            // 还白搭一次尝试、把账号继续往"需要验证码"的状态里推。
            // 账号密码照样填好，用户只要补个验证码再点登录。
            var capRe = /captcha|validate|checkcode|verifycode|kaptcha|randomcode/i;
            var needCaptcha = false;
            var ci;
            var capImgs = document.querySelectorAll('img');
            for (ci = 0; ci < capImgs.length; ci++) {
              var csrc = capImgs[ci].getAttribute('src') || '';
              if (capRe.test(csrc) && isVisible(capImgs[ci])) {
                needCaptcha = true; break;
              }
            }
            if (!needCaptcha) {
              var capIns = document.querySelectorAll('input');
              for (ci = 0; ci < capIns.length; ci++) {
                var cid = (capIns[ci].id || '') + ' '
                        + (capIns[ci].getAttribute('name') || '');
                if (capRe.test(cid) && isVisible(capIns[ci])) {
                  needCaptcha = true; break;
                }
              }
            }

            if (!okP || !u.value || !pv.value) {
              st = 'PWDFAIL';
            } else if (needCaptcha) {
              st = 'CAPTCHA';
            } else {
              var btn = document.querySelector('#loginButton')
                     || document.querySelector('#submitBtn')
                     || document.querySelector('#load')
                     || document.querySelector('button[type="submit"]')
                     || document.querySelector('input[type="submit"]');
              if (!btn) { st = 'NOBTN'; }
              else { btn.click(); st = 'CLICKED'; }
            }
          }
          return JSON.stringify({ status: st, state: state, dump: dump.join(' | ') });
        })()
      '''))?.toString() ??
          '';

      Map<String, dynamic> res = const <String, dynamic>{};
      try {
        res = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (_) {
        res = const <String, dynamic>{};
      }
      final status = (res['status'] ?? '').toString();
      final dump = (res['dump'] ?? '').toString();
      if (dump.isNotEmpty) _domDump = dump;

      // 页面上挂着验证码：这次不提交，账号密码已经填好，把网页交给用户补验证码。
      // 把 _autoSubmitted 也置上，是为了让 _onUrl 之后走"读页面反馈"而不是
      // 又回来重新自动填 —— 否则用户填完验证码提交，我们还会再插一手。
      if (status == 'CAPTCHA') {
        _autoSubmitted = true;
        if (mounted) {
          setState(() {
            _fillState = (res['state'] ?? '').toString();
            _pageError = '需要验证码，请在网页上输入后点登录';
          });
        }
        _reveal(hint: '请在网页上输入验证码');
        return;
      }

      if (status == 'CLICKED') {
        _autoSubmitted = true;
        if (mounted) {
          setState(() {
            _fillState = (res['state'] ?? '').toString();
            _hint = '正在登录…';
          });
        }
        _watchStuck();
        return;
      }

      // 没提交成功（页面没渲染完 / 密码被清空 / 找不到按钮）：稍后重试
      if ((res['state'] ?? '').toString().isNotEmpty) {
        _fillState = (res['state'] ?? '').toString();
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted || _popped || _phase != _Phase.login || _autoSubmitted) return;
      _autoBusy = false;
      await _autoFill(c);
      return;
    } catch (_) {
      // 注入失败就交给用户手动在页面上操作
    } finally {
      _autoBusy = false;
    }
  }

  /// 提交之后的盯梢：轮询看页面给什么反应。
  ///
  /// 不只用 onLoadStop —— 表单 POST 后**地址没变**，页面只是重渲染了一下，
  /// 弹出来的 `.bh-alert-box` 未必每次都伴随一次可用的 URL 回调，
  /// 所以这里自己按节奏读几遍，读到结论就提前收工。
  Future<void> _watchStuck() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (!mounted || _phase != _Phase.login || _popped || _webVisible) return;
      final c = _controller;
      if (c == null) return;
      await _readPageError(c);
      // 已经有结论了：密码错会 pop 走，验证码已经把网页露出来了
      if (_popped || _webVisible || _pageError != null) return;
    }
    if (!mounted || _phase != _Phase.login || _popped || _webVisible) return;
    // 还停在认证页上 → 多半是按钮没被认下来，总之自动这条路走不通了
    if (_lastUrl.contains('/authserver/login')) {
      _reveal(hint: '请在页面上完成登录');
    }
  }

  /// 读登录页给出的反馈，分两类处理（见类注释）。
  ///
  /// 密码错的弹窗长这样：
  ///   `<div class="bh-alert-box" style="top:194px;">您提供的用户名或者密码有误</div>`
  Future<void> _readPageError(InAppWebViewController c) async {
    String raw;
    try {
      raw = (await c.evaluateJavascript(source: '''
        (function () {
          function txt(el) { return el && el.innerText ? el.innerText.trim() : ''; }

          // 1) 明确的错误弹窗（密码错 / 账号不存在）
          var box = document.querySelector('.bh-alert-box')
                 || document.querySelector('#bh-alert-box')
                 || document.querySelector('#showErrorTip')
                 || document.querySelector('.login-error')
                 || document.querySelector('#errorMsg');
          var msg = txt(box);

          // 2) 有的页面把提示直接写在正文里
          var body = document.body ? document.body.innerText : '';
          if (!msg) {
            var pats = ['用户名或者密码有误', '用户名或密码错误', '账号或密码错误',
                        '密码错误', '用户名不存在'];
            for (var i = 0; i < pats.length; i++) {
              if (body.indexOf(pats[i]) >= 0) { msg = pats[i]; break; }
            }
          }

          // 3) 验证码：它是在密码错很多次之后才出现的，出现了就必须人来做
          var re = /captcha|validate|checkcode|verifycode|kaptcha|randomcode/i;
          var cap = false;
          var imgs = document.querySelectorAll('img');
          for (var i = 0; i < imgs.length; i++) {
            if (re.test(imgs[i].getAttribute('src') || '')) { cap = true; break; }
          }
          if (!cap) {
            var ins = document.querySelectorAll('input');
            for (var i = 0; i < ins.length; i++) {
              var idn = (ins[i].id || '') + ' ' + (ins[i].getAttribute('name') || '');
              if (re.test(idn)) { cap = true; break; }
            }
          }
          // innerText 不含 display:none 的内容，所以页面上"藏着不用"的验证码
          // 字样不会误判
          if (!cap && body.indexOf('验证码') >= 0) cap = true;
          // 同一个 bh-alert-box，要验证码时它说的是"请输入验证码"。
          // 弹窗可能是 display:none 弹出的（这时 body.innerText 里没有它），
          // 所以弹窗自己的文字也得单独看一眼，否则会被当成密码错退回去。
          if (!cap && msg.indexOf('验证码') >= 0) cap = true;

          return JSON.stringify({ kind: cap ? 'captcha' : (msg ? 'cred' : ''), msg: msg });
        })()
      '''))?.toString() ??
          '';
    } catch (_) {
      return;
    }

    Map<String, dynamic> res;
    try {
      res = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final kind = (res['kind'] ?? '').toString();
    final msg = (res['msg'] ?? '').toString();
    if (kind.isEmpty) return;

    if (!mounted) return;

    if (kind == 'captcha') {
      const text = '需要验证码，请在网页上输入后点登录';
      if (_pageError != text) setState(() => _pageError = text);
      _reveal(hint: '请在网页上输入验证码');
      return;
    }

    // 账号密码错。自绘模式下这是确定的失败，没必要让用户看网页 ——
    // 带着原因退回自绘登录页重输，全程不露出网页。
    final reason = msg.isEmpty ? '用户名或密码错误' : msg;
    if (widget.auto) {
      _failToSelfDrawn(reason);
    } else {
      // 手动模式（用户自己选了登录方式进来的）：页面本来就是他的，原地提示即可
      if (_pageError != reason) setState(() => _pageError = reason);
    }
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

  /// 登录用的 WebView。
  ///
  /// 静默的时候靠外面套 [Opacity] 的 0 来"不画"，图片、进度条一概没有。
  /// **绝不能**换成 Offstage / 尺寸 0 / `Visibility(visible:false)`：那三者会让
  /// WebView 失去真实布局，`getBoundingClientRect()` 返回 0，自动填充直接失效
  /// —— v1.0.4 的"密码填不进去"就是这么来的。Opacity 只影响绘制、不影响布局。
  ///
  /// 它也比"上面盖一层"更彻底：Android 上 WebView 是交给系统合成的 platform
  /// view，只靠 Flutter 组件盖住，偶尔会漏出一帧（就是那一瞬间闪出来的网页）。
  Widget _buildWebView() {
    return InAppWebView(
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
    );
  }

  /// 静默阶段的界面：**什么都没有**。
  ///
  /// 用户要的是"自动登录完全静默、没有任何界面"，所以这里不是"盖一层"，
  /// 而是整页透明 + 不吃点击 —— 露出来的是下面那一页（课表）自己的加载状态。
  /// 配合 [AutoLogin.attempt] 里那个 `opaque: false` 的路由，
  /// 从打开 App 到进课表，全程不会闪出任何登录界面。
  ///
  /// 两条纪律：
  ///  - 整页 [IgnorePointer]：透明的页面绝不能偷吃点击，否则用户在课表上
  ///    划不动、点不动，感觉像卡死。
  ///  - 吞掉返回键，改成"把网页露出来"：自动登录要是慢了，用户会本能地按
  ///    返回，而在这一页按返回 = 取消自动登录 = 弹出账号密码登录页 ——
  ///    那正是用户抱怨的那个界面。按一下先让他看看到底卡在哪，再按一下才是
  ///    真的取消。
  Widget _buildSilentBody() {
    // 泛型要跟所在的 Route 对上（这里是 PageRouteBuilder<LoginResult>），
    // 对不上在 debug 下会触发断言。
    return PopScope<LoginResult>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _reveal(hint: '请在页面上完成登录');
      },
      child: IgnorePointer(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Opacity(opacity: 0, child: _buildWebView()),
        ),
      ),
    );
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

    // 静默阶段：整页透明、不吃点击。用户看到的是下面那一页（课表）自己的
    // 加载状态 —— 自动登录不该占屏，更不该闪出一个登录界面。
    if (_silent) return _buildSilentBody();

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
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _autoSubmitted
                        ? '已自动填入（$_fillState）并提交；若出现验证码，请在页面上输入后点「登录」。'
                        : '正在自动填入账号密码…（$_fillState）',
                    style: const TextStyle(fontSize: 13),
                  ),
                  // 把登录页真实的输入框结构露出来，便于排错
                  if (_domDump.isNotEmpty)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('查看登录页表单结构（排错用）',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      children: [
                        SelectableText(
                          _domDump,
                          style: const TextStyle(
                              fontSize: 11, fontFamily: 'monospace'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          // 走到这里网页一定是可见的：静默那种情况在上面就 return 掉了
          Expanded(child: _buildWebView()),
        ],
      ),
    );
  }
}
