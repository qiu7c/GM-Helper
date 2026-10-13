import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gdgm_schedule/services/schedule_prefs.dart';
import 'package:gdgm_schedule/widgets/app_theme.dart';
import 'package:gdgm_schedule/widgets/glass_backdrop.dart';

/// 用户反馈：「设置页进去还是会有上个页面的内容，不够丝滑」。
///
/// 根子是页面 Scaffold 全透明（底画在 Navigator 下面），推入那 300ms 里新页面不遮
/// 旧页面，而列表的行又没有自己的底色，于是旧页面的内容整片透出来。
///
/// 修法是每个路由自己画一层不透明的底（`AppTheme._transitions`）。这里钉住两件事：
///  * **新页面自己有底** —— 改之前 `find.byType(GlassBackdrop)` 会是 0（底只在
///    main.dart 的 builder 里画一层），所以这条测试真的会红；
///  * 每个平台都配到了 —— 漏一个平台就会退回默认转场，那层底就没了。
///
/// ⚠ `find.byType` 默认 `skipOffstage: true`，推入之后底下的路由是 offstage 的，
/// 所以数到的那一个**就是最上面那页自己的**，正是要验的东西。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SchedulePrefs.instance.load();
  });

  Future<void> pushSecondPage(WidgetTester tester, TargetPlatform platform) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        theme: AppTheme.light().copyWith(platform: platform),
        home: const Scaffold(body: Text('第一页')),
      ),
    );
    nav.currentState!.push<void>(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('第二页'))),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('起始路由就有一层底', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: Text('第一页')),
      ),
    );
    expect(find.byType(GlassBackdrop), findsOneWidget);
  });

  // 六个平台逐个来。平台名会让失败信息一眼看出是哪个平台漏了。
  for (final platform in TargetPlatform.values) {
    testWidgets('$platform：推入的页面自己也有一层不透明的底', (tester) async {
      await pushSecondPage(tester, platform);
      expect(
        find.byType(GlassBackdrop),
        findsOneWidget,
        reason: '$platform 上推入的页面没有自己的底 → 转场时会透出上一个页面的内容',
      );
      expect(find.text('第二页'), findsOneWidget);
      // **不透明**才是这次修复的本体：只要底色带一点透明，旧页面的内容照样会透出来。
      final base = tester.widget<ColoredBox>(
        find
            .descendant(
              of: find.byType(GlassBackdrop),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      expect(base.color.alpha, 255, reason: '$platform 上那层底是半透明的，等于没遮');
      // 那层底必须**铺满整页**。Stack 默认 loose，忘了 StackFit.expand 的话它会缩成
      // 内容高度，页面底下露出的就是窗口底色（安卓上黑的）。
      expect(
        tester.getSize(find.byType(GlassBackdrop)),
        tester.getSize(find.byType(Scaffold).last),
        reason: '$platform 上那层底没有铺满页面',
      );
    });
  }
}