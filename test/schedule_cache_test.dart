import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gdgm_schedule/config.dart';
import 'package:gdgm_schedule/models/course.dart';
import 'package:gdgm_schedule/services/schedule_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 缓存里的 key 与 'at' 字段名在 ScheduleCache 里是私有的，这里按字面量取用。
/// 只用于构造“过期/缺时间戳”这两种历史数据，业务读写仍走公开 API。
const _cacheKey = 'schedule_cache_v1';

Course _course(String name, {List<int> weeks = const [1, 2, 3]}) => Course(
      name: name,
      teacher: '董加敏',
      room: '实803',
      teachingClass: '天河$name' '01',
      rawWeeks: '1-3(周)[01-02节]',
      weeks: weeks,
      day: 1,
      period: 1,
      sectionRange: '01-02节',
    );

ScheduleResult _result({
  List<String> names = const ['数据库原理及应用'],
  String? selectedTerm = '2026-2027-1',
  String? selectedCampus = AppConfig.campusTianhe,
  String remark = '军事技能 1-15周;',
}) =>
    ScheduleResult(
      courses: names.map(_course).toList(),
      selectedTerm: selectedTerm,
      selectedCampus: selectedCampus,
      remark: remark,
    );

/// 直接改落盘的 JSON：用来伪造过期 / 缺时间戳的历史缓存。
Future<void> _mutateEntry(Map<String, dynamic> Function(Map<String, dynamic>) f) async {
  final sp = await SharedPreferences.getInstance();
  final all = jsonDecode(sp.getString(_cacheKey)!) as Map<String, dynamic>;
  final k = all.keys.first;
  all[k] = f((all[k] as Map).cast<String, dynamic>());
  await sp.setString(_cacheKey, jsonEncode(all));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('基本读写', () {
    test('没写过时读出来是 null', () async {
      expect(await ScheduleCache.read(user: 'u1', term: 't1', campus: 'c1'), isNull);
    });

    test('写进去能原样读出来', () async {
      await ScheduleCache.write(
        user: 'u1',
        term: 't1',
        campus: 'c1',
        result: _result(names: ['数据库原理及应用', '高等数学']),
      );

      final got = await ScheduleCache.read(user: 'u1', term: 't1', campus: 'c1');
      expect(got, isNotNull);
      expect(got!.courses.map((c) => c.name).toList(),
          ['数据库原理及应用', '高等数学']);
      expect(got.selectedTerm, '2026-2027-1');
      expect(got.selectedCampus, AppConfig.campusTianhe);
      expect(got.remark, '军事技能 1-15周;');
      // 周次也要活下来，否则整学期过滤视图会空
      expect(got.courses.first.weeks, [1, 2, 3]);
    });

    test('空课表不写：一次异常响应不能把好数据覆盖掉', () async {
      await ScheduleCache.write(
        user: 'u1',
        term: 't1',
        campus: 'c1',
        result: _result(names: ['数据库']),
      );
      await ScheduleCache.write(
        user: 'u1',
        term: 't1',
        campus: 'c1',
        result: const ScheduleResult(courses: []), // 空表
      );

      final got = await ScheduleCache.read(user: 'u1', term: 't1', campus: 'c1');
      expect(got, isNotNull, reason: '空表不该把已有缓存清掉');
      expect(got!.courses.map((c) => c.name).toList(), ['数据库']);
    });

    test('空课表本身也读不出缓存（宁可转圈也别显示空表）', () async {
      await ScheduleCache.write(
        user: 'u1',
        term: 't1',
        campus: 'c1',
        result: const ScheduleResult(courses: []),
      );
      expect(await ScheduleCache.read(user: 'u1', term: 't1', campus: 'c1'), isNull);
    });
  });

  group('key 按「账号 + 学期 + 校区」隔离', () {
    test('换账号读不到上一个人的课表', () async {
      await ScheduleCache.write(
        user: 'u1', term: 't1', campus: 'c1', result: _result(names: ['甲']));
      expect(await ScheduleCache.read(user: 'u2', term: 't1', campus: 'c1'), isNull);
    });

    test('换学期互不影响', () async {
      await ScheduleCache.write(
        user: 'u1', term: 't1', campus: 'c1', result: _result(names: ['甲']));
      expect(await ScheduleCache.read(user: 'u1', term: 't2', campus: 'c1'), isNull);
    });

    test('换校区互不影响', () async {
      await ScheduleCache.write(
        user: 'u1', term: 't1', campus: 'c1', result: _result(names: ['甲']));
      expect(await ScheduleCache.read(user: 'u1', term: 't1', campus: 'c2'), isNull);
    });

    test('user/term/campus 为 null 也能存取（同一把 key）', () async {
      await ScheduleCache.write(result: _result(names: ['甲']));
      final got = await ScheduleCache.read();
      expect(got?.courses.map((c) => c.name).toList(), ['甲']);
    });
  });

  group('过期与容错', () {
    test('很久以前的缓存**照样能读**（旧数据不作废，只要没退出登录）', () async {
      // 这里原来断言的是"超过 30 天视为没有缓存"。那条规则删掉了：只要用户没点过
      // 退出登录，课表就不该消失 —— 假期里断网几十天再打开 App，看到的应该还是
      // 上学期那张表，而不是空白。
      await ScheduleCache.write(
        user: 'u1', term: 't1', campus: 'c1', result: _result());
      await _mutateEntry((e) => {
            ...e,
            'at': DateTime.now()
                .subtract(const Duration(days: 400))
                .toIso8601String(),
          });

      final got = await ScheduleCache.read(user: 'u1', term: 't1', campus: 'c1');
      expect(got, isNotNull, reason: '缓存不该因为"旧"而被判死');
      // 时间戳仍读得到，好让顶部那句"显示的是缓存（N 天前）"说实话
      final at = await ScheduleCache.cachedAt(user: 'u1', term: 't1', campus: 'c1');
      expect(at, isNotNull);
      expect(DateTime.now().difference(at!).inDays, greaterThan(300));
    });

    test('缺时间戳（早期版本写的）不算过期 —— 宁可旧一点也不作废', () async {
      await ScheduleCache.write(
        user: 'u1', term: 't1', campus: 'c1', result: _result());
      await _mutateEntry((e) => {...e}..remove('at'));

      expect(await ScheduleCache.read(user: 'u1', term: 't1', campus: 'c1'), isNotNull);
      expect(await ScheduleCache.cachedAt(user: 'u1', term: 't1', campus: 'c1'), isNull);
    });

    test('cachedAt 能读回写入时间，且约等于现在', () async {
      await ScheduleCache.write(
        user: 'u1', term: 't1', campus: 'c1', result: _result());
      final at = await ScheduleCache.cachedAt(user: 'u1', term: 't1', campus: 'c1');
      expect(at, isNotNull);
      expect(DateTime.now().difference(at!).inMinutes, lessThan(1));
    });

    test('落盘 JSON 被写坏时当没有缓存，而不是抛异常', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_cacheKey, '{ 这不是合法 JSON');
      expect(await ScheduleCache.read(user: 'u1', term: 't1', campus: 'c1'), isNull);
    });
  });

  group('容量与清理', () {
    test('最多留 6 份，最旧的被挤掉', () async {
      for (var i = 1; i <= 7; i++) {
        await ScheduleCache.write(
          user: 'u$i', term: 't1', campus: 'c1', result: _result(names: ['课$i']));
      }

      expect(await ScheduleCache.read(user: 'u1', term: 't1', campus: 'c1'), isNull,
          reason: '第 1 份应被挤掉');
      for (var i = 2; i <= 7; i++) {
        expect(await ScheduleCache.read(user: 'u$i', term: 't1', campus: 'c1'),
            isNotNull, reason: '第 $i 份应还在');
      }
    });

    test('重复写同一把 key 不会把它算成多份', () async {
      for (var i = 0; i < 8; i++) {
        await ScheduleCache.write(
          user: 'same', term: 't1', campus: 'c1', result: _result(names: ['课$i']));
      }
      final got = await ScheduleCache.read(user: 'same', term: 't1', campus: 'c1');
      expect(got, isNotNull);
      expect(got!.courses.first.name, '课7', reason: '后写的应覆盖先写的');
    });

    test('clear() 清空全部', () async {
      await ScheduleCache.write(
        user: 'u1', term: 't1', campus: 'c1', result: _result());
      await ScheduleCache.clear();
      expect(await ScheduleCache.read(user: 'u1', term: 't1', campus: 'c1'), isNull);
    });
  });
}