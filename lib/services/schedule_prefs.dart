import 'package:flutter/material.dart';

import '../config.dart';
import '../models/course.dart';
import 'auth_store.dart';

/// 全新安装（从没选过背景）时用哪一套。
///
/// **1 =「默认」**（浅色近白、深色纯黑）。这里原来是 0（冷岩）。改的理由：既然有一套
/// 就叫「默认」，应用的默认值就不该是另一套 —— 名字和默认值对不上，用户会以为选错了。
/// **已经选过背景的用户存的是数字，完全不受这个改动影响。**
///
/// ⚠ 常量放在这里而不是 `glass_backdrop.dart`：那边 import 了本文件，放过去就是循环
/// 依赖。`test/backdrop_styles_test.dart` 会拿它跟 `kBackdropStyles` 对一遍。
const int kDefaultBackdropId = 1;

/// 全局的课表偏好（学期/校区/日历）。「我的」页修改后通知课表页自动重载。
class SchedulePrefs {
  SchedulePrefs._();
  static final SchedulePrefs instance = SchedulePrefs._();

  /// 学期/校区变更时自增，课表页监听它触发重载
  final ValueNotifier<int> revision = ValueNotifier(0);

  /// 背景方案 id。
  ///
  /// **单独一个 notifier，不能并进 [revision]**：`GlassBackdrop` 挂在
  /// `MaterialApp.builder` 上，是两个页面共用的一层底 —— 换背景要重画的是它，
  /// 跟"学期换了、课表重拉"是两回事。混在一起会让换背景顺带触发一次课表请求。
  ///
  /// 初值就是 [kDefaultBackdropId]：`load()` 是异步的，第一帧还读不到用户存的值，
  /// 初值给错的话全新安装会先闪一下冷岩再变成「默认」。
  final ValueNotifier<int> background = ValueNotifier(kDefaultBackdropId);

  /// 自定义背景图（已拷进 App 私有目录的绝对路径）。null = 用 [background] 那套色斑。
  final ValueNotifier<String?> backgroundImage = ValueNotifier(null);

  /// 自定义背景图的模糊半径（逻辑像素）。**只作用于背景图本身**，跟玻璃自带的那层
  /// `BackdropFilter` 是两回事：这里管的是"壁纸要不要糊"。
  final ValueNotifier<double> backgroundBlur = ValueNotifier(0);

  /// 深浅色：跟随系统 / 浅色 / 深色。`main.dart` 监听它决定 `MaterialApp.themeMode`。
  ///
  /// 单独一个 notifier 的理由和 [background] 一样：它改的是整棵树的外层，
  /// 跟"学期换了、课表重拉"（[revision]）没有关系。
  final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);

  String? _term;
  String? _campus;

  /// 学期第一周周一（来自教务日历，缺省用配置兜底）
  DateTime _firstMonday = AppConfig.termFirstMonday;
  int _totalWeeks = 20;

  String? get term => _term;
  String? get campus => _campus;
  DateTime get firstMonday => _firstMonday;
  int get totalWeeks => _totalWeeks;

  /// 当前背景方案 id
  int get bgStyle => background.value;

  /// 当前自定义背景图路径，没有则为 null
  String? get bgImage => backgroundImage.value;

  /// 当前背景图模糊半径
  double get bgBlur => backgroundBlur.value;

  /// 当前深浅色模式
  ThemeMode get theme => themeMode.value;

  Future<void> load() async {
    _term = await AuthStore.getLastTerm();
    _campus = await AuthStore.getLastCampus();
    final fm = await AuthStore.getFirstMonday();
    if (fm != null) _firstMonday = fm;
    _totalWeeks = await AuthStore.getTotalWeeks() ?? 20;
    background.value = await AuthStore.getBgStyle() ?? kDefaultBackdropId;
    backgroundImage.value = await AuthStore.getBgImage();
    backgroundBlur.value = await AuthStore.getBgBlur() ?? 0;
    // 越界（老版本存过别的值、文件被改过）一律回落到跟随系统，别让 enum 取值抛
    final tm = await AuthStore.getThemeMode() ?? ThemeMode.system.index;
    themeMode.value = (tm >= 0 && tm < ThemeMode.values.length)
        ? ThemeMode.values[tm]
        : ThemeMode.system;
  }

  Future<void> setBgStyle(int id) async {
    if (id == background.value) return;
    await AuthStore.saveBgStyle(id);
    background.value = id;
  }

  Future<void> setBgImage(String? path) async {
    if (path == backgroundImage.value) return;
    await AuthStore.saveBgImage(path ?? '');
    backgroundImage.value = path;
  }

  Future<void> setBgBlur(double v) async {
    if (v == backgroundBlur.value) return;
    await AuthStore.saveBgBlur(v);
    backgroundBlur.value = v;
  }

  Future<void> setThemeMode(ThemeMode m) async {
    if (m == themeMode.value) return;
    await AuthStore.saveThemeMode(m.index);
    themeMode.value = m;
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
