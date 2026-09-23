import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../widgets/glass_nav_bar.dart';
import 'profile_page.dart';
import 'timetable_page.dart';

/// 主壳：底部导航切换「课表」和「我的」
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin {
  int _index = 0;

  // 用 key 让切回"我的"时能重新检查登录状态
  final _profileKey = GlobalKey();

  /// 切标签页时的淡入。
  ///
  /// **这里必须继续用 `IndexedStack`**，换 `PageView` 不只是换个写法：
  /// `IndexedStack` 会把两个子页面**都**构建出来（两个 `initState` 都会跑），
  /// 而这个 App 是**故意**依赖"启动时两页同时发请求、同时判出会话失效"这个
  /// 交错的 —— profile_page 里那段 `clearSession(failedCookie:)` 就是为它写的。
  /// `PageView` 只构建可见页，「我的」启动时压根不会构造，那条竞态就消失了，
  /// 等于顺手改了启动逻辑，不属于"换个皮"该干的事。
  late final AnimationController _tabAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    // 从"已播完"开始，免得第一帧无端闪一下
    value: 1,
  );

  @override
  void dispose() {
    _tabAnim.dispose();
    super.dispose();
  }

  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    _tabAnim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    // 在**壳 Scaffold 之上**读，这里拿到的才是真正的窗口内边距。
    // 一旦进了 Scaffold 的 body，Scaffold 会把 padding.bottom 换成底栏槽位的
    // 高度，home indicator 那 34px 就没人管了 —— 底栏会直接压在 home 条上。
    final safeBottom = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      // 内容从底栏**底下**穿过去，玻璃才有东西可模糊。
      //
      // 副作用正好是我们要的：body 拿到的 padding.bottom 会被 Scaffold 换成
      // 底栏槽位的**实测高度**（含下面 Padding 的边距），所以两个页面的滚动区
      // 自动就留出了位置 —— 不用自己算常量，也不会重复计算。
      extendBody: true,
      body: FadeTransition(
        opacity: Tween<double>(begin: 0.55, end: 1.0).animate(
          CurvedAnimation(parent: _tabAnim, curve: Curves.easeOut),
        ),
        child: IndexedStack(
          index: _index,
          children: [
            const TimetablePage(),
            ProfilePage(key: _profileKey),
          ],
        ),
      ),
      bottomNavigationBar: GestureDetector(
        // 底栏四周那圈留白（左右各 16、底下那截安全区）不在玻璃上，点击会穿到
        // 下面去 —— 右边那条正好压在周日那一列上，点个空白可能弹出课程详情。
        // 这层不透明手势把留白处吃掉。里面的格子比它深，会先赢下手势竞技场，
        // 正常点击不受影响。
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: Padding(
          // 底下留 12 是视觉上的悬空；但真到了有 home indicator 的机器上，
          // 12 不够，得用安全区高度，否则胶囊压在 home 条上
          padding: EdgeInsets.fromLTRB(16, 0, 16, math.max(12.0, safeBottom)),
          child: GlassNavBar(index: _index, onSelected: _select),
        ),
      ),
    );
  }
}
