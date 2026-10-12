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
///
/// key 里带着**用户名**：会话过期时缓存是不清的（见 `AuthStore.clearSession`），
/// 带上账号才能保证换个人登录时不会先闪一眼上一个人的课表。
class ScheduleCache {
  ScheduleCache._();

  static const _kKey = 'schedule_cache_v1';

  /// 最多留几份，避免换账号/学期/校区后无限堆积
  static const _maxEntries = 6;

  // ⚠ **这里刻意没有"过期时间"。**
  //
  // 原来有一道 `_maxAge = 30 天`：太久的缓存当作没有。删掉的理由是它和用户的预期
  // 相反 —— 只要没点过「退出登录」，课表就不该消失。30 天这道线会在"假期里断网很久
  // 没打开 App"这种情况下把一份本来还有效的课表判死，用户看到的是空白 + 转圈，而
  // 他什么都没做错。
  //
  // 删掉之后不会积累旧数据，因为：
  //  * 每次联网成功都会**覆盖**同一把 key 的缓存（key 是 用户|学期|校区）；
  //  * 学期换了就是另一把 key，不会串；
  //  * 用户主动退出登录时 `clear()` 清掉全部。
  //
  // 也就是说，这份数据只在"用户没退出登录"这个前提下长期保留 —— 而那个前提正是
  // 我们要的语义。

  /// key = 用户 | 学期 | 校区 | **周次**
  ///
  /// ⚠ **周次必须进 key，这是修 bug 加上的。**
  ///
  /// 教务是**按周返回**的：`ScheduleService.fetch(week:)` 会把周次当成 `zc` 参数发给
  /// 教务，同一学期的第 7 周和第 8 周拿到的是**两套不同的课程**（实测：第 7 周 8 门、
  /// 第 8 周 1 门）。
  ///
  /// 原来 key 里没有周次，于是会发生这样一串：
  ///   1. 翻到第 8 周 → 联网刷新 → 缓存被**第 8 周**的数据覆盖；
  ///   2. 重进 App（回到第 7 周）→ 读到的却是第 8 周那份缓存；
  ///   3. 课表页拿"屏幕上这份"（第 8 周）当基线，去比刚拉回来的第 7 周课表 →
  ///      **必然**报出一堆"新增 N 门、取消 M 门"。
  /// 用户看到的不是"学校调课了"，而是"切周弹、重进还弹，一直反复弹窗"。
  static String _keyOf(String? user, String? term, String? campus, String? week) =>
      '${user ?? ''}|${term ?? ''}|${campus ?? ''}|${week ?? ''}';

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
  /// （注意这里**没有过期判定**，理由见 `_maxEntries` 上面那段。）
  static Future<ScheduleResult?> read({
    String? user,
    String? term,
    String? campus,
    required String? week,
  }) async {
    final all = await _readAll();
    final entry = all[_keyOf(user, term, campus, week)];
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

  /// 这份缓存是什么时候抓的。课表页拿它显示「N 天前的课表」。
  static Future<DateTime?> cachedAt({
    String? user,
    String? term,
    String? campus,
    required String? week,
  }) async {
    final all = await _readAll();
    final entry = all[_keyOf(user, term, campus, week)];
    if (entry is! Map) return null;
    return _timeOf(entry.cast<String, dynamic>());
  }

  /// 时间戳缺失（早期版本写进去的、或数据被手工改过）不算异常 ——
  /// 读不到 'at' 只影响"上次更新于多久前"那句提示，缓存本身照用。
  static DateTime? _timeOf(Map<String, dynamic> e) =>
      DateTime.tryParse((e['at'] ?? '').toString());

  static Future<void> write({
    String? user,
    String? term,
    String? campus,
    required String? week,
    required ScheduleResult result,
  }) async {
    // 空课表不写：否则一次异常的响应就把好数据覆盖掉了
    if (result.courses.isEmpty) return;
    final all = await _readAll();
    final k = _keyOf(user, term, campus, week);
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

  /// 用户主动退出登录时清掉。会话过期**不要**调这个 ——
  /// 那种情况下课表本身还是有效的，留着比清掉有用（见 `AuthStore.clearSession`）。
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
