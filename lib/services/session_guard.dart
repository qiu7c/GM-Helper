/// 判断教务系统的一次响应是否表示"会话已失效，需要重新登录"。
///
/// 只认两个硬信号：
///  1. HTTP 3xx —— 未登录时教务系统会 302 跳到统一身份认证；
///  2. 返回体确实是一个登录页（CAS 登录表单 / 密码加密盐）。
///
/// 千万不能用 '用户登录' / 'login.jsp' 这类子串判断：
/// 正常业务页面里也会出现（例如会话超时的 JS 里就写着 login.jsp），
/// 那样会把"登录成功"误判成"未登录"，进而把好端端的 Cookie 清掉。
class SessionGuard {
  const SessionGuard._();

  /// CAS 登录页特征：表单 id 与密码加密盐（只有登录页才有）
  static const List<String> _loginPageMarkers = [
    'casLoginForm',
    'pwdDefaultEncryptSalt',
  ];

  /// 正文里是否出现 [markers] 里的任意一个。
  ///
  /// 配合 [looksLoggedOut] 用来堵一个很隐蔽的洞：会话失效后，教务系统**不一定**
  /// 会跳转。它也可能安安静静回一个 200 的"会话超时"过渡页（页面里靠 JS 自己
  /// 跳），那种页面既不是 3xx，正文里也没有 CAS 登录表单 —— [looksLoggedOut]
  /// 两条都认不出来，于是解析器照常跑、解析出一份空数据。
  ///
  /// 用户看到的就是那个很迷惑的现象：**还显示已登录，但课表和学籍信息全空**，
  /// 而且怎么刷新都出不来。
  ///
  /// 所以再加一条正面判断：真业务页面一定有它的结构锚点。一个锚点都没有，
  /// 说明拿到的根本不是业务页面。锚点要挑**只有这个页面才有**的字符串，
  /// 不能挑 '用户登录' 这种满世界都是的词。
  static bool containsAnyOf(String body, List<String> markers) {
    for (final m in markers) {
      if (body.contains(m)) return true;
    }
    return false;
  }

  /// [status] 为 HTTP 状态码，[body] 为响应正文。
  static bool looksLoggedOut(int? status, String body) {
    if (status == null) return false;
    // 1) 重定向：教务系统未登录时的标准行为
    if (status >= 300 && status < 400) return true;
    // 2) 只有 200 才看正文，其它错误码(如 500)交给各自的错误处理
    if (status != 200) return false;
    for (final m in _loginPageMarkers) {
      if (body.contains(m)) return true;
    }
    return false;
  }
}
