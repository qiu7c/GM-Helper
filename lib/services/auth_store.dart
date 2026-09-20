import 'package:shared_preferences/shared_preferences.dart';

/// 负责持久化会话 Cookie 及用户上次选择
class AuthStore {
  static const _kCookie = 'jw_cookie';
  static const _kTerm = 'last_term';
  static const _kCampus = 'last_campus';
  static const _kUsername = 'saved_username';

  /// 保存登录后抓取到的 Cookie 字符串（形如 "JSESSIONID=xxx; ..."）
  static Future<void> saveCookie(String cookie) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kCookie, cookie);
  }

  static Future<String?> getCookie() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kCookie);
  }

  static Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kCookie);
  }

  static Future<bool> isLoggedIn() async {
    final c = await getCookie();
    return c != null && c.isNotEmpty;
  }

  static Future<void> saveLastTerm(String term) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kTerm, term);
  }

  static Future<String?> getLastTerm() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kTerm);
  }

  static Future<void> saveLastCampus(String campus) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kCampus, campus);
  }

  static Future<String?> getLastCampus() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kCampus);
  }

  /// 记住上次登录的学号/工号（不保存密码），登录页自动回填
  static Future<void> saveUsername(String username) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kUsername, username);
  }

  static Future<String?> getSavedUsername() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kUsername);
  }
}
