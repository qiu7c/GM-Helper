import 'package:flutter_test/flutter_test.dart';
import 'package:gdgm_schedule/services/session_guard.dart';

void main() {
  group('looksLoggedOut 识别“会话失效”', () {
    test('3xx 一律判为失效（教务未登录时就是 302 去 SSO）', () {
      expect(SessionGuard.looksLoggedOut(302, ''), isTrue);
      expect(SessionGuard.looksLoggedOut(301, ''), isTrue);
      expect(SessionGuard.looksLoggedOut(303, ''), isTrue);
      expect(SessionGuard.looksLoggedOut(399, ''), isTrue);
    });

    test('200 且正文是 CAS 登录表单 -> 失效', () {
      expect(
        SessionGuard.looksLoggedOut(200, '<form id="casLoginForm">...</form>'),
        isTrue,
      );
    });

    test('200 且正文含密码加密盐 -> 失效（登录页独有）', () {
      expect(
        SessionGuard.looksLoggedOut(200, 'var pwdDefaultEncryptSalt = "abc";'),
        isTrue,
      );
    });

    test('200 的正常业务页 -> 不算失效', () {
      expect(
        SessionGuard.looksLoggedOut(200, '<table id="kbtable"></table>'),
        isFalse,
      );
    });

    test('200 里出现 "login.jsp" 字样也不算失效', () {
      // 这条是注释里特意警告过的坑：会话超时的 JS 里就写着 login.jsp，
      // 拿子串判会把“登录成功”误判成“未登录”，进而把好 Cookie 清掉。
      expect(
        SessionGuard.looksLoggedOut(200, 'window.location="login.jsp"'),
        isFalse,
      );
    });

    test('200 里出现 "用户登录" 字样也不算失效', () {
      expect(SessionGuard.looksLoggedOut(200, '<div>用户登录</div>'), isFalse);
    });

    test('200 且正文是强智自己的登录页 -> 失效（照实测页面抄的）', () {
      // 这一段是按**真页面**抄的（2026-10 实测：未登录请求课表接口，回的就是它）。
      // 它正是原来判不出来的原因：
      //   * HTTP 200 —— 不跳转；
      //   * 正文里**没有** CAS 表单 / 加密盐（那是 sfrz 那边的登录页特征）；
      //   * 靠 JS 自己跳 /sso.jsp。
      // 于是只能落到"课表锚点一个都没有"那条兜底，而那条分不清掉登录和教务抽风。
      const realPage = '''
        <html><head><title>登录</title></head><body>
        <div class="login-box"><h3>用户登录</h3>
        <p>请先登录系统</p>
        <script>window.location.href="/sso.jsp"</script>
        </div></body></html>
      ''';
      expect(SessionGuard.looksLoggedOut(200, realPage), isTrue);
    });

    test('业务页里"会话超时后跳 /sso.jsp"的脚本不算失效', () {
      // 反面，也是**故意**不收 /sso.jsp 当标记的原因：路径类子串不能当判据
      //（类注释里 login.jsp 那条就是踩过这个坑）。标记只收「请先登录系统」
      // 这种登录页上写给人看的文案。
      const business =
          '<div>课表</div><script>window.location.href="/sso.jsp"</script>';
      expect(SessionGuard.looksLoggedOut(200, business), isFalse);
    });

    test('状态码为 null -> false（宁可放过也不误清登录态）', () {
      expect(SessionGuard.looksLoggedOut(null, 'casLoginForm'), isFalse);
    });

    test('5xx 只看状态码，不看正文里的登录页特征', () {
      expect(SessionGuard.looksLoggedOut(500, 'casLoginForm'), isFalse);
      expect(SessionGuard.looksLoggedOut(502, 'pwdDefaultEncryptSalt'), isFalse);
    });

    test('404 不会被误判成失效', () {
      expect(SessionGuard.looksLoggedOut(404, 'casLoginForm'), isFalse);
    });

    test('边界：300 起算重定向 -> 失效', () {
      expect(SessionGuard.looksLoggedOut(300, 'casLoginForm'), isTrue);
      expect(SessionGuard.looksLoggedOut(399, 'casLoginForm'), isTrue);
    });

    test('边界：299 既不是重定向也不是 200 -> 交给上层错误处理', () {
      // 实现里是「非 200 一律不看正文」，所以这里必须是 false：
      // 否则一个奇怪的状态码会被当成会话失效，把好 Cookie 清掉。
      expect(SessionGuard.looksLoggedOut(299, 'casLoginForm'), isFalse);
    });
  });

  group('containsAnyOf 结构锚点', () {
    test('命中任意一个即为真', () {
      expect(SessionGuard.containsAnyOf('xxkbtablexx', ['xnxq01id', 'kbtable']), isTrue);
    });

    test('一个都没命中为假', () {
      expect(SessionGuard.containsAnyOf('空课表过渡页', ['xnxq01id', 'kbtable']), isFalse);
    });

    test('空标记列表恒为假', () {
      expect(SessionGuard.containsAnyOf('任意内容', const []), isFalse);
    });

    test('空正文恒为假', () {
      expect(SessionGuard.containsAnyOf('', ['kbtable']), isFalse);
    });
  });
}