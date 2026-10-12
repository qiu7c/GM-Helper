import 'package:flutter_test/flutter_test.dart';
import 'package:gdgm_schedule/models/course.dart';
import 'package:gdgm_schedule/services/schedule_diff.dart';

Course _c(
  String name, {
  int day = 1,
  int period = 1,
  String room = '实803',
  String teacher = '董加敏',
  List<int> weeks = const [1, 2, 3],
}) =>
    Course(
      name: name,
      teacher: teacher,
      room: room,
      teachingClass: '',
      rawWeeks: '1-3(周)[01-02节]',
      weeks: weeks,
      day: day,
      period: period,
      sectionRange: '01-02节',
    );

void main() {
  group('ScheduleDiff.compare', () {
    test('一模一样 -> 空差异（不提示）', () {
      final d = ScheduleDiff.compare([_c('数据库')], [_c('数据库')]);
      expect(d.isEmpty, isTrue);
      expect(d.total, 0);
    });

    test('多了一门 -> added', () {
      final d = ScheduleDiff.compare([_c('数据库')], [_c('数据库'), _c('体育', day: 2)]);
      expect(d.added.map((c) => c.name).toList(), ['体育']);
      expect(d.removed, isEmpty);
      expect(d.changed, isEmpty);
      expect(d.isEmpty, isFalse);
    });

    test('少了一门 -> removed', () {
      final d = ScheduleDiff.compare([_c('数据库'), _c('体育', day: 2)], [_c('数据库')]);
      expect(d.removed.map((c) => c.name).toList(), ['体育']);
      expect(d.added, isEmpty);
    });

    test('同一格换了教室 -> changed', () {
      final d = ScheduleDiff.compare([_c('数据库')], [_c('数据库', room: '教304')]);
      expect(d.changed.map((c) => c.name).toList(), ['数据库']);
      // 换教室不该同时算成"新增+取消"
      expect(d.added, isEmpty);
      expect(d.removed, isEmpty);
    });

    test('同一格换了老师 -> changed', () {
      final d = ScheduleDiff.compare([_c('数据库')], [_c('数据库', teacher: '谭武')]);
      expect(d.changed.length, 1);
    });

    test('周次变了 -> changed（"这门课从第 10 周才开始上"是最常见的一种）', () {
      final d = ScheduleDiff.compare(
        [_c('数据库', weeks: [1, 2, 3])],
        [_c('数据库', weeks: [1, 2, 3, 10, 11])],
      );
      expect(d.changed.length, 1);
    });

    test('周次只有顺序不同 -> 不算变化（解析顺序不保证稳定，比了会天天误报）', () {
      final d = ScheduleDiff.compare(
        [_c('数据库', weeks: [3, 1, 2])],
        [_c('数据库', weeks: [1, 2, 3])],
      );
      expect(d.isEmpty, isTrue);
    });

    test('同一门课挪到别的大节 -> 算增 + 删，不算"改"', () {
      // 判定单位是"课名+星期+大节"：位置变了就是另一格，把它算成"改"会让用户
      // 以为这门课没动过
      final d = ScheduleDiff.compare([_c('数据库')], [_c('数据库', period: 3)]);
      expect(d.added.length, 1);
      expect(d.removed.length, 1);
      expect(d.changed, isEmpty);
    });

    test('summary 只列出现过的类别', () {
      final d = ScheduleDiff.compare(
        [_c('A'), _c('B', day: 2)],
        [_c('A', room: '换了'), _c('C', day: 3)],
      );
      // A 改了教室、B 没了、C 是新的
      expect(d.summary(), '新增 1 门、取消 1 门、调整 1 处');
    });
  });
}