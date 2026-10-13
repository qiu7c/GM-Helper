import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/update_notifier.dart';
import '../services/update_service.dart';
import '../widgets/glass_backdrop.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/update_prompt.dart';
import 'profile_page.dart';
import 'timetable_page.dart';

/// 主壳：底部导航切换「课表」和「我的」
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  // 用 key 让切回"我的"时能重新检查登录状态
  final _profileKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 启动检测更新。等第一帧画完再发，别跟首屏那两个请求抢网络和主线程。
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoCheckUpdate());
  }

  /// 每次启动查一次有没有新版本。
  ///
  /// 只有**真的发现**新版本才打扰用户：发一条系统通知 + 弹一个 App 内弹窗。
  /// 同一个版本只提醒一次（`UpdateService.announceOnce`）—— 检测每次都跑，但每次
  /// 启动都把同一个版本再弹一遍就成了骚扰。
  ///
  /// 任何失败（离线、加速站全挂、分发仓没建）都静默收场：检查更新失败不是用户的事。
  Future<void> _autoCheckUpdate() async {
    final info = await UpdateService.check();
    if (info == null || !mounted) return;
    if (!await UpdateService.announceOnce(info.version)) return;
    // 先把下载线路在后台定下来，用户点「去下载」时就不用等
    UpdateService.prefetchDownload(info);
    await UpdateNotifier.show(info);
    if (!mounted) return;
    await showUpdatePrompt(context, info);
  }

  // ⚠ **切标签页没有过渡动画，这是故意的（原来是有的，删掉了）。**
  //
  // 原来这里是一个 220ms 的**全屏**淡入：`_select` 里 `_tabAnim.forward(from: 0)`，
  // body 套一层 `FadeTransition(begin: 0.55, end: 1.0)`。
  //
  // 它在实机 iOS 上正是用户报的那个"延迟动画"：点一下底栏，新页面的内容从 55% 不
  // 透明度糊到 100%，两百多毫秒里"内容才慢慢出来"。而且 `FadeTransition` 的 opacity
  // 只要不是 1 就得开一次 `saveLayer` —— 那是**整屏**、每帧一次，还压在玻璃模糊上，
  // 于是又糊又卡。
  //
  // 更要紧的是：**iOS 原生 TabBar 切页是瞬间的，本来就没有淡入。** 这个动画没让它
  // 更精致，只让它不像 iOS 该有的样子。切页就该是瞬时的。
  //
  // 只删动画，`IndexedStack` 照旧 —— 换 `PageView` 是另一件事：
  // `IndexedStack` 会把两个子页面**都**构建出来（两个 `initState` 都会跑），而这个
  // App 是**故意**依赖"启动时两页同时发请求、同时判出会话失效"这个交错的 ——
  // profile_page 里那段 `clearSession(failedCookie:)` 就是为它写的。
  // `PageView` 只构建可见页，「我的」启动时压根不会构造，那条竞态就消失了，
  // 等于顺手改了启动逻辑，不属于"换个皮"该干的事。
  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
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
          IndexedStack(
            index: _index,
            children: [
              const TimetablePage(),
              ProfilePage(key: _profileKey),
            ],
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
