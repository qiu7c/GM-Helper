import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/course.dart';
import 'auth_store.dart';

/// 全局的课表偏好（学期/校区/日历）。「我的」页修改后通知课表页自动重载。
class SchedulePrefs {
  SchedulePrefs._();
  static final SchedulePrefs instance = SchedulePrefs._();

  /// 学期/校区变更时自增，课表页监听它触发重载
  final ValueNotifier<int> revision = ValueNotifier(0);

  String? _term;
  String? _campus;

  /// 学期第一周周一（来自教务日历，缺省用配置兜底）
  DateTime _firstMonday = AppConfig.termFirstMonday;
  int _totalWeeks = 20;

  String? get term => _term;
  String? get campus => _campus;
  DateTime get firstMonday => _firstMonday;
  int get totalWeeks => _totalWeeks;

  Future<void> load() async {
    _term = await AuthStore.getLastTerm();
    _campus = await AuthStore.getLastCampus();
    final fm = await AuthStore.getFirstMonday();
    if (fm != null) _firstMonday = fm;
    _totalWeeks = await AuthStore.getTotalWeeks() ?? 20;
  }

  Future<void> setTerm(String term) async {
    if (term == _term) return;
    _term = term;
    await AuthStore.saveLastTerm(term);
    revision.value++;
  }

  Future<void> setCampus(String campus) async {
    if (campus == _campus) return;
    _campus = campus;
    await AuthStore.saveLastCampus(campus);
    revision.value++;
  }

  void sync({String? term, String? campus}) {
    if (term != null) _term = term;
    if (campus != null) _campus = campus;
  }

  /// 用教务日历更新第一周周一与总周数（登录/加载时调用）
  Future<void> applyCalendar(TermCalendar cal) async {
    _firstMonday = cal.firstMonday;
    _totalWeeks = cal.totalWeeks;
    await AuthStore.saveFirstMonday(cal.firstMonday);
    await AuthStore.saveTotalWeeks(cal.totalWeeks);
  }

  /// 某日期属于第几周（1..totalWeeks，超范围截断）
  int weekOfDate(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    final diff = d.difference(_firstMonday).inDays;
    if (diff < 0) return 1;
    final w = diff ~/ 7 + 1;
    return w > _totalWeeks ? _totalWeeks : w;
  }

  /// 当前（今天）是第几周
  int currentWeek() => weekOfDate(DateTime.now());

  /// 某周的周一日期
  DateTime mondayOfWeek(int week) =>
      _firstMonday.add(Duration(days: (week - 1) * 7));
}
