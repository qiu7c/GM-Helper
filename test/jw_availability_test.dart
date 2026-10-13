import 'package:flutter_test/flutter_test.dart';

import 'package:gdgm_schedule/services/jw_availability.dart';

/// 探针真去 ping 学校这件事本身没法在 CI 里测（没网，也不该拿学校的服务器做测试），
/// 所以把**判断**抽成了纯函数，这里只测判断 —— 而那正是容易写错的地方。
///
/// 这一组里最要紧的是第三条：两个都连不上时**不能**赖学校。那更可能是用户自己的网，
/// 把锅甩错方向，用户就会一直等一个不会自己好的东西。
void main() {
  bool down(JwReach jw, {required bool portal}) =>
      JwAvailability.schoolLooksDown(jw: jw, portalAlive: portal);

  test('教务自己回 5xx：直接就是学校的问题，跟门户通不通无关', () {
    expect(down(JwReach.serverError, portal: true), isTrue);
    expect(down(JwReach.serverError, portal: false), isTrue);
  });

  test('教务连不上、门户答得上：是教务自己不在', () {
    expect(down(JwReach.unreachable, portal: true), isTrue);
  });

  test('教务连不上、门户也连不上：更可能是自己的网，不赖学校', () {
    expect(down(JwReach.unreachable, portal: false), isFalse);
  });

  test('教务答得上（200 / 跳登录页）：它活着，这次失败是别的原因', () {
    expect(down(JwReach.up, portal: true), isFalse);
    expect(down(JwReach.up, portal: false), isFalse);
    expect(down(JwReach.loginRequired, portal: true), isFalse);
    expect(down(JwReach.loginRequired, portal: false), isFalse);
  });
}