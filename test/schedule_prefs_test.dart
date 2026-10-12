import 'package:flutter_test/flutter_test.dart';
import 'package:gdgm_schedule/config.dart';
import 'package:gdgm_schedule/models/course.dart';
import 'package:gdgm_schedule/services/auth_store.dart';
import 'package:gdgm_schedule/services/schedule_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 注意：这几个用例**依赖单例的默认状态**（首周一取 AppConfig.termFirstMonday、
/// 总周数 20）。会改动单例的用例一律放在文件末尾，避免影响前面的断言。
/// 每个测试文件在独立 isolate 里跑，所以不用担心和别的文件互相污染。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('weekOfDate（用默认校历：首周一 2026-08-31，共 20 周）', () {
    test('默认首周一确实是周一', () {
      expect(AppConfig.termFirstMonday.weekday, DateTime.monday);
    });

    test('首周一当天是第 1 周', () {
      expect(SchedulePrefs.instance.weekOfDate(DateTime(2026, 8, 31)), 1);
    });

    test('第 1 周的周日仍是第 1 周（不能提前进第 2 周）', () {
      expect(SchedulePrefs.instance.weekOfDate(DateTime(2026, 9, 6)), 1);
    });

    test('下一个周一是第 2 周', () {
      expect(SchedulePrefs.instance.weekOfDate(DateTime(2026, 9, 7)), 2);
    });

    test('第 3 周的周三是第 3 周', () {
      expect(SchedulePrefs.instance.weekOfDate(DateTime(2026, 9, 16)), 3);
    });

    test('开学前钳到第 1 周', () {
      expect(SchedulePrefs.instance.weekOfDate(DateTime(2026, 8, 30)), 1);
      expect(SchedulePrefs.instance.weekOfDate(DateTime(2020, 1, 1)), 1);
    });

    test('学期结束后钳到最后一周，不会算出第 300 周', () {
      expect(SchedulePrefs.instance.weekOfDate(DateTime(2030, 1, 1)),
          SchedulePrefs.instance.totalWeeks);
    });

    test('带时分秒的 DateTime 不影响结果（内部按天归一）', () {
      expect(SchedulePrefs.instance.weekOfDate(DateTime(2026, 9, 7, 23, 59)), 2);
    });
  });

  group('mondayOfWeek', () {
    test('第 1 周的周一是首周一', () {
      expect(SchedulePrefs.instance.mondayOfWeek(1), AppConfig.termFirstMonday);
    });

    test('第 3 周的周一是 2026-09-14', () {
      expect(SchedulePrefs.instance.mondayOfWeek(3), DateTime(2026, 9, 14));
    });

    test('与 weekOfDate 自洽：某周的周一应落回该周', () {
      for (var w = 1; w <= SchedulePrefs.instance.totalWeeks; w++) {
        final monday = SchedulePrefs.instance.mondayOfWeek(w);
        expect(SchedulePrefs.instance.weekOfDate(monday), w, reason: '第 $w 周不自洽');
      }
    });

    test('每周的周一都是周一', () {
      for (var w = 1; w <= SchedulePrefs.instance.totalWeeks; w++) {
        expect(SchedulePrefs.instance.mondayOfWeek(w).weekday, DateTime.monday,
            reason: '第 $w 周的周一算错了');
      }
    });
  });

  group('未知日期范围不应越界', () {
    test('weekOfDate 的结果永远落在 [1, totalWeeks]', () {
      final prefs = SchedulePrefs.instance;
      var d = DateTime(2026, 1, 1);
      for (var i = 0; i < 400; i++) {
        final w = prefs.weekOfDate(d);
        expect(w, greaterThanOrEqualTo(1));
        expect(w, lessThanOrEqualTo(prefs.totalWeeks));
        d = d.add(const Duration(days: 3));
      }
    });
  });

  // ---- 以下用例会改动单例与本地存储，放在最后 ----
  group('applyCalendar 持久化（会改单例状态）', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('写入后立即可读，且首周一/总周数与校历一致', () async {
      final cal = TermCalendar(
        currentWeek: 3,
        totalWeeks: 18,
        date: DateTime(2026, 9, 16),
      );
      await SchedulePrefs.instance.applyCalendar(cal);

      expect(SchedulePrefs.instance.firstMonday, DateTime(2026, 8, 31));
      expect(SchedulePrefs.instance.totalWeeks, 18);
    });

    test('落盘了：AuthStore 能读回同一份', () async {
      final cal = TermCalendar(
        currentWeek: 2,
        totalWeeks: 17,
        date: DateTime(2026, 9, 9),
      );
      await SchedulePrefs.instance.applyCalendar(cal);

      expect(await AuthStore.getFirstMonday(), DateTime(2026, 8, 31));
      expect(await AuthStore.getTotalWeeks(), 17);
    });

    test('总周数变了之后，钳位跟着新的走', () async {
      await SchedulePrefs.instance.applyCalendar(
        TermCalendar(currentWeek: 1, totalWeeks: 5, date: DateTime(2026, 8, 31)),
      );
      expect(SchedulePrefs.instance.weekOfDate(DateTime(2026, 12, 1)), 5);
    });
  });
}