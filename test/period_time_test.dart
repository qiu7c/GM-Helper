import 'package:flutter_test/flutter_test.dart';
import 'package:gdgm_schedule/config.dart';
import 'package:gdgm_schedule/models/period_time.dart';

void main() {
  group('各校区作息时间', () {
    test('天河第一大节 08:00-09:40', () {
      final t = PeriodTime.of(AppConfig.campusTianhe, 1);
      expect(t, isNotNull);
      expect(t!.startText, '08:00');
      expect(t.endText, '09:40');
      expect(t.startMin, 8 * 60);
      expect(t.endMin, 9 * 60 + 40);
    });

    test('白云第一大节 08:30-10:05（与天河不同）', () {
      final t = PeriodTime.of(AppConfig.campusBaiyun, 1);
      expect(t!.startText, '08:30');
      expect(t.endText, '10:05');
    });

    test('荔湾第五大节 19:00-20:35', () {
      final t = PeriodTime.of(AppConfig.campusLiwan, 5);
      expect(t!.startText, '19:00');
      expect(t.endText, '20:35');
    });

    test('荔湾没有第六大节 -> null（而不是抛异常）', () {
      expect(PeriodTime.of(AppConfig.campusLiwan, 6), isNull);
    });

    test('天河有第六大节，别被荔湾的特殊情况带偏', () {
      expect(PeriodTime.of(AppConfig.campusTianhe, 6), isNotNull);
    });
  });

  group('越界与兜底', () {
    test('未知校区回退到默认作息', () {
      final t = PeriodTime.of('不存在的校区id', 1);
      expect(t, isNotNull);
      expect(t!.startText, AppConfig.periodTimes.first.split('\n').first);
    });

    test('校区为 null 也走默认作息', () {
      expect(PeriodTime.of(null, 1), isNotNull);
    });

    test('大节号 0 越界 -> null', () {
      expect(PeriodTime.of(AppConfig.campusTianhe, 0), isNull);
    });

    test('大节号 7 越界 -> null', () {
      expect(PeriodTime.of(AppConfig.campusTianhe, 7), isNull);
    });
  });

  group('containsMinute 左闭右开', () {
    late PeriodTime t;

    setUp(() {
      t = PeriodTime.of(AppConfig.campusTianhe, 1)!; // 480..580
    });

    test('开始前一分钟不算在上课', () {
      expect(t.containsMinute(479), isFalse);
    });

    test('开始那一分钟算在上课（左闭）', () {
      expect(t.containsMinute(480), isTrue);
    });

    test('结束前一分钟还算在上课', () {
      expect(t.containsMinute(579), isTrue);
    });

    test('结束那一分钟不算（右开）—— 否则课间会误报"正在上课"', () {
      expect(t.containsMinute(580), isFalse);
    });
  });

  group('AppConfig.periodTime 原始字符串', () {
    test('未知校区返回默认表', () {
      expect(AppConfig.periodTime('xx', 1), AppConfig.periodTimes[0]);
    });

    test('荔湾第六大节是空串占位', () {
      expect(AppConfig.periodTime(AppConfig.campusLiwan, 6), '');
    });

    test('大节号越界返回空串', () {
      expect(AppConfig.periodTime(AppConfig.campusTianhe, 99), '');
      expect(AppConfig.periodTime(AppConfig.campusTianhe, -1), '');
    });
  });

  group('配置自洽性', () {
    test('三个校区都在作息表里，且都是 6 格（荔湾第 6 格为空）', () {
      for (final id in [
        AppConfig.campusTianhe,
        AppConfig.campusBaiyun,
        AppConfig.campusLiwan,
      ]) {
        expect(AppConfig.campusPeriodTimes[id], isNotNull, reason: '校区 $id 缺作息表');
        expect(AppConfig.campusPeriodTimes[id]!.length, AppConfig.periodCount);
      }
    });

    test('作息字符串都是 "HH:MM\\nHH:MM" 两行（空格占位除外）', () {
      final re = RegExp(r'^\d{2}:\d{2}\n\d{2}:\d{2}$');
      for (final entry in AppConfig.campusPeriodTimes.entries) {
        for (final slot in entry.value) {
          if (slot.isEmpty) continue; // 荔湾第六大节的占位
          expect(re.hasMatch(slot), isTrue, reason: '${entry.key} 的 "$slot" 格式不对');
        }
      }
    });

    test('每个校区的每一节都能解析出开始 < 结束', () {
      for (final id in AppConfig.campusPeriodTimes.keys) {
        for (var p = 1; p <= AppConfig.periodCount; p++) {
          final t = PeriodTime.of(id, p);
          if (t == null) continue;
          expect(t.startMin < t.endMin, isTrue, reason: '校区 $id 第 $p 节起止时间颠倒');
        }
      }
    });

    test('大节名称数量与 periodCount 一致', () {
      expect(AppConfig.periodNames.length, AppConfig.periodCount);
    });

    test('星期名称恰好 7 个', () {
      expect(AppConfig.weekDayNames.length, 7);
    });
  });
}