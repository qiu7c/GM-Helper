import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 登录页里那段注入 JS 的**源码级**护栏。
///
/// 为什么用这种笨办法：验证码判断写在 `evaluateJavascript` 的字符串里，
/// `flutter test` 里没有浏览器、执行不了它。而这里要挡的是一个**真出过的 bug**，
/// 所以宁可笨一点也要拦一道（同类做法见 `changelog_format_test.dart`，
/// 它也是直接读文件断言的）。
///
/// bug 的原样：CAS 登录页**永远**带着
///   `<div id="cpatchaDiv" style="display:none">
///      <input id="captchaResponse" …> <img id="captchaImg" src="captcha.html">`
/// 只按 src/id 匹配、不判可见性的话，**不管页面回什么都会判成"需要验证码"** ——
/// 密码错的提示被它盖掉，用户看到的是"密码明明错了，却说你得填验证码"，
/// 而且每次都是。
void main() {
  final src = File('lib/pages/login_page.dart').readAsStringSync();

  test('提交之后那次判断必须连可见性一起判，不能只看 src/id', () {
    // 反面断言：这一行正是出过 bug 的写法，注释里还写着"innerText 不含
    // display:none 所以不会误判"—— 但那两圈循环根本没判可见性。
    expect(
      src.contains(
          "if (re.test(imgs[i].getAttribute('src') || '')) { cap = true; break; }"),
      isFalse,
      reason: '隐藏的 captchaImg（src=captcha.html）也会命中，页面回什么都会被判成需要验证码',
    );
    // 正面：要有可见性判断，而且两个分支都得挂上
    expect(src.contains('function capVisible(el)'), isTrue);
    expect(src.contains('&& capVisible(imgs[i])'), isTrue);
    expect(src.contains('&& capVisible(ins[i])'), isTrue);
  });

  test('提交之前那次判断必须以页面自己的 needCaptcha 为准', () {
    // App 自己填表时先 focus 用户名、再 focus 密码，恰好触发页面的
    // `mobileUsername.onblur` → 页面**异步**去问 needCaptcha.html →
    // 那一行验证码是**被我们自己引出来的**。抢在 AJAX 回来之前按"看得见就算要"
    // 下结论，就会把一次本来能成功的登录判死。所以要优先采信页面那个全局变量
    //（它是问过权威接口的），可见性只做它缺席时的兜底。
    expect(
      src.contains("var pageSays = (typeof needCaptcha === 'boolean') "
          '? needCaptcha : null;'),
      isTrue,
    );
    expect(
      src.contains('var capNeeded = (pageSays !== null) ? pageSays : capSeen;'),
      isTrue,
    );
  });

  test('把网页交给用户之前要把账号密码补回去', () {
    // CAS 登录失败后是重渲染一份**空表单**（POST 回来后页面整个重来一遍），
    // App 早先填进去的值就不在了。不补填的话，用户看到的是一个空登录页，
    // 还得自己重新敲一遍账号密码 —— 而他明明是让 App 自动登的。
    expect(src.contains('_refillForUser()'), isTrue);
    expect(src.contains("if (status == 'FILLED')"), isTrue);
    // 补填只做一次，别把用户已经敲进去的内容覆盖掉
    expect(src.contains('if (_refilledForUser || !widget.auto) return;'), isTrue);
  });
}