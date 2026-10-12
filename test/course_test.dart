import 'package:flutter_test/flutter_test.dart';
import 'package:gdgm_schedule/models/course.dart';

/// 造一个课程，只关心 weeks / day / period 的用例不必重复写其它字段。
Course _course({
  List<int> weeks = const [],
  int day = 1,
  int period = 1,
  String name = '数据库原理及应用',
  String teacher = '董加敏',
  String room = '实803',
  String teachingClass = '天河数据库020102',
  String rawWeeks = '3-6,10-19(周)[01-02节]',
  String sectionRange = '01-02节',
}) =>
    Course(
      name: name,
      teacher: teacher,
      room: room,
      teachingClass: teachingClass,
      rawWeeks: rawWeeks,
      weeks: weeks,
      day: day,
      period: period,
      sectionRange: sectionRange,
    );

void main() {
  group('Course.weekRange 把周次压成紧凑写法', () {
    test('没有周次时返回空串，而不是 "0" 或 "-"', () {
      expect(_course(weeks: []).weekRange, '');
    });

    test('单周不加区间', () {
      expect(_course(weeks: [5]).weekRange, '5');
    });

    test('连续周合成区间，跳号处另起一段', () {
      expect(_course(weeks: [3, 4, 5, 6, 10, 11]).weekRange, '3-6,10-11');
    });

    test('乱序输入会先排序（缓存里的顺序不保证）', () {
      expect(_course(weeks: [11, 3, 4, 6, 5, 10]).weekRange, '3-6,10-11');
    });

    test('全不连续时逐周列出', () {
      expect(_course(weeks: [1, 3, 5]).weekRange, '1,3,5');
    });

    test('单周夹在两段区间之间', () {
      expect(_course(weeks: [1, 2, 5, 8, 9]).weekRange, '1-2,5,8-9');
    });
  });

  group('Course.activeInWeek', () {
    test('命中该周为 true', () {
      expect(_course(weeks: [3, 4, 5]).activeInWeek(4), isTrue);
    });

    test('不在该周为 false', () {
      expect(_course(weeks: [3, 4, 5]).activeInWeek(6), isFalse);
    });

    test('空周次对任何周都不生效', () {
      expect(_course(weeks: []).activeInWeek(1), isFalse);
    });
  });

  group('Course JSON 往返', () {
    test('toJson -> fromJson 保持全部字段', () {
      final original = _course(weeks: [3, 4, 5, 10]);
      final restored = Course.fromJson(original.toJson());

      expect(restored.name, original.name);
      expect(restored.teacher, original.teacher);
      expect(restored.room, original.room);
      expect(restored.teachingClass, original.teachingClass);
      expect(restored.rawWeeks, original.rawWeeks);
      expect(restored.weeks, original.weeks);
      expect(restored.day, original.day);
      expect(restored.period, original.period);
      expect(restored.sectionRange, original.sectionRange);
    });

    test('缺字段时不会抛异常，落到默认值', () {
      final restored = Course.fromJson(<String, dynamic>{});
      expect(restored.name, '');
      expect(restored.weeks, isEmpty);
      expect(restored.day, 1);
      expect(restored.period, 1);
    });
  });

  group('TermCalendar.firstMonday 反推学期首周一', () {
    test('第 3 周的周三 -> 首周一为 2026-08-31', () {
      final cal = TermCalendar(
        currentWeek: 3,
        totalWeeks: 20,
        date: DateTime(2026, 9, 16), // 周三
      );
      expect(cal.firstMonday, DateTime(2026, 8, 31));
    });

    test('第 1 周的周一就是首周一本身', () {
      final cal = TermCalendar(
        currentWeek: 1,
        totalWeeks: 20,
        date: DateTime(2026, 8, 31),
      );
      expect(cal.firstMonday, DateTime(2026, 8, 31));
    });

    test('结果里不含时间部分（否则后面按天相减会差一天）', () {
      final cal = TermCalendar(
        currentWeek: 2,
        totalWeeks: 20,
        date: DateTime(2026, 9, 9, 13, 45), // 带时分
      );
      expect(cal.firstMonday, DateTime(2026, 8, 31));
      expect(cal.firstMonday.hour, 0);
      expect(cal.firstMonday.minute, 0);
    });
  });
}