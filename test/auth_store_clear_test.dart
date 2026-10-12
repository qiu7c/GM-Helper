import 'package:flutter_test/flutter_test.dart';
import 'package:gdgm_schedule/models/course.dart';
import 'package:gdgm_schedule/services/auth_store.dart';
import 'package:gdgm_schedule/services/schedule_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 这两条守的是**「退出登录」和「会话过期」的区别** —— 这是用户明确提出的一条语义：
///
///  * 退出登录：登录态**和课表缓存**一起清（他不想在这台机器上留东西）
///  * 会话过期：只清登录态，**课表留着**（课表本身还是有效的，重登之前也该看得见）
///
/// 两边是反的，所以各钉一条。改动这里之前先想清楚动的是哪一种。

const _user = 'u1';
const _term = '2026-2027-1';
const _campus = '3589FB3E8AD246BCBAD7BB5C8710D078';

Course _course() => const Course(
      name: '数据库原理及应用',
      teacher: '董加敏',
      room: '实803',
      teachingClass: '天河01',
      rawWeeks: '1-3(周)[01-02节]',
      weeks: [1, 2, 3],
      day: 1,
      period: 1,
      sectionRange: '01-02节',
    );

Future<void> _seed() async {
  SharedPreferences.setMockInitialValues({});
  await AuthStore.saveCookie('JSESSIONID=4B3E67B2FFA65BD88E94362FB6826E31');
  await ScheduleCache.write(
    user: _user,
    term: _term,
    campus: _campus,
    week: '7',
    result: ScheduleResult(courses: [_course()], selectedTerm: _term),
  );
}

Future<bool> _hasCache() async =>
    (await ScheduleCache.read(
            user: _user, term: _term, campus: _campus, week: '7')) !=
    null;

void main() {
  test('退出登录：登录态和课表缓存一起清掉', () async {
    await _seed();
    expect(await AuthStore.getCookie(), isNotNull, reason: '前置：本来是有登录态的');
    expect(await _hasCache(), isTrue, reason: '前置：本来是有缓存的');

    await AuthStore.clear();

    expect(await AuthStore.getCookie(), isNull, reason: '登录态必须清掉');
    expect(await _hasCache(), isFalse, reason: '退出登录要连课表缓存一起清');
  });

  test('会话过期：只清登录态，课表缓存留着', () async {
    await _seed();

    await AuthStore.clearSession();

    expect(await AuthStore.getCookie(), isNull, reason: '过期的票要清掉');
    expect(await _hasCache(), isTrue,
        reason: '课表本身还有效：清掉的话，用户重登之前打开就是一片空白');
  });

  test('只有「主动退出」才发退出通知，会话过期不发', () async {
    // 课表页靠这个信号决定要不要把**内存里那份**课表也丢掉（它活在 IndexedStack 里，
    // 光清磁盘缓存，切回去照样画得出来）。两条路都会让 authRevision 自增，所以
    // 必须有一个分开的通知，否则"会话过期"会被当成"退出"、课表被无谓地清掉。
    await _seed();
    final authBefore = AuthStore.authRevision.value;
    final logoutBefore = AuthStore.logoutRevision.value;

    await AuthStore.clearSession();

    expect(AuthStore.authRevision.value, greaterThan(authBefore),
        reason: '会话过期也要通知页面重新检查登录态');
    expect(AuthStore.logoutRevision.value, logoutBefore,
        reason: '会话过期不是"用户退出"，不能触发清内存里的课表');

    await AuthStore.clear();

    expect(AuthStore.logoutRevision.value, greaterThan(logoutBefore),
        reason: '用户主动退出必须发退出通知');
  });
}