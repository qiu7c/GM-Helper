import '../models/course.dart';

/// 两次课表之间的差异。
///
/// 用途只有一个：这次刷新回来的课表和**屏幕上那份**（缓存或上次的结果）不一样时，
/// 明确告诉用户"课表变了"。教务是会在学期中途调课、加课的，而用户不会每天都去核对
/// 一遍课表 —— 换教室这种事只在上课前才发现，就太晚了。
///
/// 判定单位是 **课程名 + 星期 + 大节**，也就是"同一格里的同一门课"，不是 `Course`
/// 整体相等：教务每次返回的字段顺序、周次串的写法都可能不同，直接比对象会把"其实
/// 没变"判成"变了"，那就成了天天误报的噪音。
class ScheduleDiff {
  const ScheduleDiff({
    this.added = const [],
    this.removed = const [],
    this.changed = const [],
  });

  /// 这次新出现的课（教务加课、或者原来是别的格子）
  final List<Course> added;

  /// 这次不见了的课（教务取消，或者挪到了别的格子 —— 那样它会同时出现在 added 里）
  final List<Course> removed;

  /// 位置没变、但内容变了的课：周次、教室、老师
  final List<Course> changed;

  bool get isEmpty => added.isEmpty && removed.isEmpty && changed.isEmpty;

  int get total => added.length + removed.length + changed.length;

  static String _keyOf(Course c) => '${c.name}|${c.day}|${c.period}';

  /// 这两份结果**能不能比**。
  ///
  /// ⚠ **必须同一周。** 教务是按周返回的（周次是发给它的 `zc` 参数，见
  /// `ScheduleService.fetch`）：同一学期的第 7 周和第 8 周是两套完全不同的课程
  /// （实测 8 门 vs 1 门）。拿它们互比，报出来的"新增/取消"跟"学校调课"毫无关系。
  ///
  /// 用户就是这么撞上的：翻一周、或者退出重进（回到当前周），屏幕上那份属于另一周，
  /// 于是**每次都弹**"课表有变化"，怎么点都还在弹。
  ///
  /// 判据用 `selectedWeek` —— 它是从教务返回的那份解析出来的，就是这份数据所属的周。
  /// **两边都得有、且相等才比；拿不准就不比。** 宁可漏报也不能误报：误报一次，这个
  /// 提示就再也没人信了（见本文件开头那段）。
  static bool comparable(ScheduleResult? before, ScheduleResult after) {
    final pw = before?.selectedWeek;
    final nw = after.selectedWeek;
    return pw != null && nw != null && pw == nw;
  }

  /// 拿 [before]（屏幕上那份）和 [after]（刚拉回来的）比对。
  static ScheduleDiff compare(List<Course> before, List<Course> after) {
    final b = <String, Course>{for (final c in before) _keyOf(c): c};
    final a = <String, Course>{for (final c in after) _keyOf(c): c};

    final added = <Course>[];
    final removed = <Course>[];
    final changed = <Course>[];

    for (final e in a.entries) {
      final old = b[e.key];
      if (old == null) {
        added.add(e.value);
      } else if (_differs(old, e.value)) {
        changed.add(e.value);
      }
    }
    for (final e in b.entries) {
      if (!a.containsKey(e.key)) removed.add(e.value);
    }
    return ScheduleDiff(added: added, removed: removed, changed: changed);
  }

  /// 同一格里的同一门课，哪些变化算"调课"：
  ///
  ///  * **周次**变了 —— 最常见的一种（"这门课从第 10 周才开始上"）
  ///  * **教室 / 老师**变了 —— 换教室、换老师
  ///
  /// ⚠ 其余字段（`rawWeeks` 的写法、`teachingClass`、`sectionRange`）**故意不比**。
  /// 它们在教务那边经常无意义地变动，比了会天天误报，而误报一次用户就再也不信这个
  /// 提示了 —— 那比没有提示更糟。
  static bool _differs(Course a, Course b) {
    if (a.room != b.room) return true;
    if (a.teacher != b.teacher) return true;
    // 周次按集合比，不按数组顺序比：解析出来的顺序不保证稳定
    final wa = [...a.weeks]..sort();
    final wb = [...b.weeks]..sort();
    if (wa.length != wb.length) return true;
    for (var i = 0; i < wa.length; i++) {
      if (wa[i] != wb[i]) return true;
    }
    return false;
  }

  /// 一句话摘要，给提示的标题用
  String summary() {
    final parts = <String>[];
    if (added.isNotEmpty) parts.add('新增 ${added.length} 门');
    if (removed.isNotEmpty) parts.add('取消 ${removed.length} 门');
    if (changed.isNotEmpty) parts.add('调整 ${changed.length} 处');
    return parts.join('、');
  }
}