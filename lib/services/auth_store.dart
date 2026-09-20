import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 负责持久化会话 Cookie 及用户上次选择
class AuthStore {
  static const _kCookie = 'jw_cookie';
  static const _kTerm = 'last_term';
  static const _kCampus = 'last_campus';
  static const _kUsername = 'saved_username';
  static const _kFirstMonday = 'term_first_monday';
  static const _kTotalWeeks = 'term_total_weeks';

  /// 登录状态变更通知：saveCookie / clear 后自增，
  /// 供「我的」等页面监听后重新检查，避免切页时还显示旧的未登录状态。
  static final ValueNotifier<int> authRevision = ValueNotifier(0);

  /// 保存登录后抓取到的 Cookie 字符串（形如 "JSESSIONID=xxx; ..."）
  static Future<void> saveCookie(String cookie) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kCookie, cookie);
    authRevision.value++;
  }

  static Future<String?> getCookie() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kCookie);
  }

  static Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kCookie);
    authRevision.value++;
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

  /// 学期第一周周一（来自教务日历），存 ISO 字符串
  static Future<void> saveFirstMonday(DateTime d) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kFirstMonday, d.toIso8601String());
  }

  static Future<DateTime?> getFirstMonday() async {
    final sp = await SharedPreferences.getInstance();
    final s = sp.getString(_kFirstMonday);
    return s == null ? null : DateTime.tryParse(s);
  }

  static Future<void> saveTotalWeeks(int n) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kTotalWeeks, n);
  }

  static Future<int?> getTotalWeeks() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getInt(_kTotalWeeks);
  }
}
