import 'package:flutter_test/flutter_test.dart';
import 'package:gdgm_schedule/models/course.dart';
import 'package:gdgm_schedule/services/schedule_diff.dart';

Course _c(String name, {int day = 1, int period = 1}) => Course(
      name: name,
      teacher: '董加敏',
      room: '实803',
      teachingClass: '天河$name 01',
      rawWeeks: '1-3(周)[01-02节]',
      weeks: const [1, 2, 3],
      day: day,
      period: period,
      sectionRange: '01-02节',
    );

ScheduleResult _r(List<Course> cs, {String? week}) =>
    ScheduleResult(courses: cs, selectedWeek: week);

/// 「比对之前必须先确认是同一周」这件事的回归测试。
///
/// 起因是个严重 bug：用户反馈「切周、退出重进，一直反复弹『课表有变化』」。
///
/// 根因是教务**按周返回**课表（周次是发给它的 `zc` 参数），同一学期第 7 周和第 8 周
/// 是两套完全不同的课程（实测 8 门 vs 1 门）。而课表页把"屏幕上那份"当基线，那份经常
/// 属于**另一周** —— 于是每一次刷新都比出一堆"新增/取消"，可那不是学校调课。
///
/// 修法是在比对前用 `ScheduleDiff.comparable` 卡一道：两边周次都有、且相等才比。
/// 拿不准就不比 —— **宁可漏报，也不能误报**：误报一次，这个提示就再也没人信了。
void main() {
  group('比对前必须先确认是同一周', () {
    test('同一周才可比', () {
      expect(
        ScheduleDiff.comparable(
            _r([_c('体育I')], week: '7'), _r([_c('体育I')], week: '7')),
        isTrue,
      );
    });

    test('不同周不可比 —— 这正是「切周 / 重进一直弹窗」的来源', () {
      // 用实测到的真实形状：第 7 周 8 门、第 8 周 1 门
      final w7 = _r([_c('体育I'), _c('数据库原理及应用')], week: '7');
      final w8 = _r([_c('大学生职业发展与就业指导')], week: '8');

      expect(ScheduleDiff.comparable(w7, w8), isFalse,
          reason: '第 7 周 vs 第 8 周，本来就不是同一份东西，比了只会误报');

      // 把"不挡住会怎样"写下来：真比一下，报出来的就是这些噪声
      final d = ScheduleDiff.compare(w7.courses, w8.courses);
      expect(d.isEmpty, isFalse);
      expect(d.summary(), '新增 1 门、取消 2 门');
    });

    test('没有基线（第一次打开 App）不可比', () {
      expect(ScheduleDiff.comparable(null, _r([_c('甲')], week: '7')), isFalse);
    });

    test('周次缺失就不比 —— 宁可漏报也不能误报', () {
      // `selectedWeek` 是教务返回里解析出来的。老数据、响应里没有周次选择框，
      // 都可能拿不到 —— 这时候不许猜。
      expect(ScheduleDiff.comparable(_r([_c('甲')], week: '7'), _r([_c('甲')])),
          isFalse);
      expect(ScheduleDiff.comparable(_r([_c('甲')]), _r([_c('甲')], week: '7')),
          isFalse);
      expect(ScheduleDiff.comparable(_r([_c('甲')]), _r([_c('甲')])), isFalse);
    });

    test('同一周且内容真的变了，仍然要报（这个提示不能修没了）', () {
      final before = _r([_c('体育I', period: 1)], week: '7');
      final after = _r([_c('体育I', period: 1), _c('新加的课', period: 4)],
          week: '7');
      expect(ScheduleDiff.comparable(before, after), isTrue);
      final d = ScheduleDiff.compare(before.courses, after.courses);
      expect(d.summary(), '新增 1 门');
    });
  });
}