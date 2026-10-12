import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../widgets/glass_backdrop.dart';
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

  /// 底栏离屏幕底边的距离。
  ///
  /// 原来是 12 —— 胶囊几乎贴着屏底。抬到 30 是为了**给下面那层遮罩留出地方**：
  /// 遮罩是从透明渐变到背景色，只在 12px 里化开是看不出来的，等于没有。抬上来之后
  /// 胶囊下面有约 30 逻辑像素（约 77 物理像素）在做渐变，"内容淡进背景里"才读得出来。
  ///
  /// 数一下眼：想再高一点就改这一个数，遮罩高度是跟着它算的，不用两边一起改。
  static const double _navGap = 30;

  @override
  Widget build(BuildContext context) {
    // 在**壳 Scaffold 之上**读，这里拿到的才是真正的窗口内边距。
    // 一旦进了 Scaffold 的 body，Scaffold 会把 padding.bottom 换成底栏槽位的
    // 高度，home indicator 那 34px 就没人管了 —— 底栏会直接压在 home 条上。
    final safeBottom = MediaQuery.of(context).padding.bottom;
    // 有 home indicator 的机器上安全区比 30 高，取大的那个
    final gap = math.max(_navGap, safeBottom);

    return Scaffold(
      // 内容从底栏**底下**穿过去，玻璃才有东西可模糊。
      //
      // 副作用正好是我们要的：body 拿到的 padding.bottom 会被 Scaffold 换成
      // 底栏槽位的**实测高度**（含下面 Padding 的边距），所以两个页面的滚动区
      // 自动就留出了位置 —— 不用自己算常量，也不会重复计算。
      extendBody: true,
      body: Stack(
        // 不写 expand 的话 Stack 会给子节点松约束，两个页面会被缩成内容高
        fit: StackFit.expand,
        children: [
          FadeTransition(
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
          // 底部渐变遮罩。放在 **body 里**（不是放进 bottomNavigationBar）：底栏槽位
          // 的高度是内容撑出来的，放进去就不好控制它往上延伸多少；放在 body 里可以
          // 让它正好从胶囊顶边一直化到屏底，页面本来也在这里留了等高的空白。
          //
          // 它在页面之上、底栏之下 —— 顺序由 Scaffold 保证：底栏永远画在 body 后面。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: BottomFade(height: GlassNavBar.height + gap),
          ),
        ],
      ),
      // 底栏收窄成 144 宽之后改成**居中摆**，不再左右各留 16 撑满。
      //
      // ⚠ 不透明手势层跟着缩进胶囊里，这是跟着收窄**必须**做的：底栏槽位（这个
      // `Align`）仍然占满整行宽，如果在它外面套一层吃掉点击的 `GestureDetector`，
      // 屏幕底部左右两角就变成点不动的死区 —— 而 `extendBody` 让页面内容正好从
      // 那底下穿过去。收进胶囊之后，两侧的点击照旧落到页面上。
      bottomNavigationBar: Padding(
        // gap 是视觉上的悬空（见 _navGap）；真到了有 home indicator 的机器上，
        // 30 可能还不够，得用安全区高度，否则胶囊压在 home 条上
        padding: EdgeInsets.only(bottom: gap),
        child: Align(
          // heightFactor: 1 → 高度只取子节点的高度。**不设的话 Align 会吃满可用
          // 高度**（Scaffold 给底栏槽位的约束是松的），底栏会撑成半屏。
          heightFactor: 1,
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            // 只有胶囊这一小块吃掉点击：它压在课表上时，点空白不该透到下面的
            // 课程格子去。里面的格子比它深，会先赢下手势竞技场。
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: GlassNavBar(index: _index, onSelected: _select),
          ),
        ),
      ),
    );
  }
}
