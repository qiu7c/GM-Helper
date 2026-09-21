import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/course.dart';

/// 课表本地缓存。
///
/// 教务系统一次返回**整个学期**的课表（周次是客户端过滤的，见
/// `TimetablePage._visibleCourses`），所以按「学期 + 校区」存一份就够，
/// 切周次完全不用重新请求。
///
/// 用途是「先铺后刷」：打开 App 先把缓存显示出来，再后台联网刷新。
/// 教务系统抽风或断网时，至少还能看上次的课表，而不是一片空白或者转圈。
class ScheduleCache {
  ScheduleCache._();

  static const _kKey = 'schedule_cache_v1';

  /// 最多留几份，避免换学期/校区后无限堆积
  static const _maxEntries = 6;

  static String _keyOf(String? term, String? campus) =>
      '${term ?? ''}|${campus ?? ''}';

  static Future<Map<String, dynamic>> _readAll() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kKey);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, dynamic>{};
      return decoded.cast<String, dynamic>();
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// 读缓存。没有、坏了、或者是个空课表都返回 null。
  ///
  /// 空课表特意当作"没有缓存"：宁可转圈，也别拿一份空表把用户的课表抹掉。
  static Future<ScheduleResult?> read({String? term, String? campus}) async {
    final all = await _readAll();
    final entry = all[_keyOf(term, campus)];
    if (entry is! Map) return null;
    final e = entry.cast<String, dynamic>();
    try {
      final courses = (e['courses'] as List? ?? const [])
          .whereType<Map>()
          .map((c) => Course.fromJson(c.cast<String, dynamic>()))
          .toList();
      if (courses.isEmpty) return null;
      return ScheduleResult(
        courses: courses,
        terms: _opts(e['terms']),
        weeks: _opts(e['weeks']),
        campuses: _opts(e['campuses']),
        selectedTerm: e['selectedTerm']?.toString(),
        selectedWeek: e['selectedWeek']?.toString(),
        selectedCampus: e['selectedCampus']?.toString(),
        remark: (e['remark'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 这份缓存是什么时候抓的
  static Future<DateTime?> cachedAt({String? term, String? campus}) async {
    final all = await _readAll();
    final entry = all[_keyOf(term, campus)];
    if (entry is! Map) return null;
    return DateTime.tryParse((entry['at'] ?? '').toString());
  }

  static Future<void> write({
    String? term,
    String? campus,
    required ScheduleResult result,
  }) async {
    // 空课表不写：否则一次异常的响应就把好数据覆盖掉了
    if (result.courses.isEmpty) return;
    final all = await _readAll();
    final k = _keyOf(term, campus);
    all.remove(k); // 先删再插，让它排到最新
    all[k] = {
      'at': DateTime.now().toIso8601String(),
      'courses': result.courses.map((c) => c.toJson()).toList(),
      'terms': _packOpts(result.terms),
      'weeks': _packOpts(result.weeks),
      'campuses': _packOpts(result.campuses),
      'selectedTerm': result.selectedTerm,
      'selectedWeek': result.selectedWeek,
      'selectedCampus': result.selectedCampus,
      'remark': result.remark,
    };
    // Map 保持插入顺序，keys.first 就是最旧的那份
    while (all.length > _maxEntries) {
      all.remove(all.keys.first);
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kKey, jsonEncode(all));
  }

  /// 退出登录时清掉：免得换账号后先闪一眼上一个人的课表
  static Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kKey);
  }

  static List<Map<String, String>> _packOpts(List<SelectOption> opts) =>
      opts.map((o) => {'value': o.value, 'label': o.label}).toList();

  static List<SelectOption> _opts(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((o) => SelectOption(
              (o['value'] ?? '').toString(),
              (o['label'] ?? '').toString(),
            ))
        .where((o) => o.value.isNotEmpty)
        .toList();
  }
}
