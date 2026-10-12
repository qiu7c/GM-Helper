import 'package:flutter/material.dart';

import 'glass.dart';

/// 底栏的两个去处
class _Dest {
  const _Dest(this.icon, this.selectedIcon, this.label);
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

const _dests = <_Dest>[
  _Dest(Icons.calendar_view_week_outlined, Icons.calendar_view_week, '课表'),
  _Dest(Icons.person_outline, Icons.person, '我的'),
];

/// 悬浮玻璃底栏。
///
/// 换掉原来的 `NavigationBar`：从贴边整条改成一块浮起来的圆角玻璃，图标和文字
/// **一直都有**，选中那一下是靠背后一块胶囊滑过去表示的。
///
/// **只有两个去处，所以不做满宽。** 满宽时两个图标被摊在大片空白里，又大又空 ——
/// 那就是"底栏太肿大"的来源。现在按内容定宽：宽度 = 单格宽 × 2，由 `home_shell`
/// 决定摆在哪儿（居中）。
///
/// 几个刻意的选择：
///
///  * **用 `GestureDetector` 不用 `InkWell`**。`InkWell` 找的是最近的那个
///    `Material`，在这个位置就是壳 Scaffold 的 —— 而它画在底栏**下面**，
///    水波纹会被玻璃挡得一干二净，白花一次绘制。反馈交给滑动的胶囊。
///  * **补了 `Semantics`**。`NavigationBar` 自带无障碍语义，换成手搓的就没有了，
///    读屏会只念出"课表 我的"两个孤零零的词。
///  * 颜色全部取自 `colorScheme`，不再出现 `Colors.grey` 这类硬编码。
///  * **边缘不再自己传 `Border.all`**：`GlassPanel` 现在会画一圈渐变镜面描边，
///    再叠一条等宽的实线就是两条边，会脏。
class GlassNavBar extends StatelessWidget {
  const GlassNavBar({
    super.key,
    required this.index,
    required this.onSelected,
  });

  final int index;
  final ValueChanged<int> onSelected;

  /// 玻璃本体的高度。**不含**底部安全区（那个在 home_shell）。
  ///
  /// 演变：64（满宽时代）→ 52（收窄时一起压的，压过头了）→ 60。
  /// 52 配 144 宽时整体偏小，看着像贴了块邮票。
  static const double height = 60;

  /// 单格宽度。**要调底栏大小，改这一个数就够**：总宽 = 这个 × 2。
  ///
  /// 演变：72（总宽 144，屏宽的 34%，偏小）→ 112（总宽 224，屏宽的 53%）。
  /// 参照：满宽时代是 420（屏宽的 100%），所以现在仍比那时候小一半。
  static const double _itemWidth = 112;

  /// 玻璃本体的宽度。**按内容定宽**，不是满宽（见类注释）。
  static final double _width = _itemWidth * _dests.length;

  /// 选中胶囊离玻璃边缘的间距
  static const double _pillInset = 5;

  /// 滑过去的时长。太快看不出在动，太慢会拖在手指后面
  static const Duration _slide = Duration(milliseconds: 240);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      width: _width,
      height: height,
      child: GlassPanel(
        // 高度的一半 = 正胶囊形。比原来的 radiusLg(24) 更圆，这一档圆角本身
        // 就是"液态"的一部分：直角像卡片，全圆像水滴。
        borderRadius: BorderRadius.circular(height / 2),
        child: Stack(
          children: [
            // 胶囊衬在最底下
            AnimatedAlign(
              duration: _slide,
              curve: Curves.easeOutCubic,
              alignment:
                  index == 0 ? Alignment.centerLeft : Alignment.centerRight,
              child: SizedBox(
                width: _itemWidth,
                height: height,
                child: Padding(
                  padding: const EdgeInsets.all(_pillInset),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      // ⚠ 选中胶囊必须是**半透明**的，而且必须是**灰色**。两条都是
                      // 实测踩出来的，根因是同一个地方：
                      //
                      //  * 半透明 —— 原来是实心 `primaryContainer`，等于底栏有**一半
                      //    面积**是不透明的。底栏模糊"很不明显"，一大半原因就在这：
                      //    玻璃再透，被一块实心胶囊压住的地方也透不出任何东西。
                      //  * 灰色 —— 之前取 `primary`/`primaryContainer`，而种子色
                      //    0xFF2A2A2C 的**蓝分量比红绿高 2**，`neutral` 变体会把这丝
                      //    色相留在主色上，选中项看起来就"发蓝"。这里直接点名
                      //    `onSurface` 那一档灰，不再依赖从种子推导出来的色相。
                      color: scheme.onSurface.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(
                        (height - _pillInset * 2) / 2,
                      ),
                    ),
                    // DecoratedBox 没有子节点时会缩成 0，得撑一下
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                for (var i = 0; i < _dests.length; i++)
                  SizedBox(
                    width: _itemWidth,
                    child: _item(context, theme, i),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext context, ThemeData theme, int i) {
    final scheme = theme.colorScheme;
    final on = i == index;
    final dest = _dests[i];
    // 选中/未选中都走灰阶：选中那档更深、字更重，不靠色相区分。
    // 用 `onSurface` 而不是 `primary`，理由见选中胶囊那段的注释（种子带一丝蓝）。
    final fg = on ? scheme.onSurface : scheme.onSurfaceVariant;

    return Semantics(
      // ⚠ 这里**不要**再给一遍 `label: dest.label`：里面那个 `Text` 已经把
      // "课表"写进语义树了，两处都给会被合并成 "课表\n课表"，读屏连念两遍
      // （uiautomator 实测的 content-desc 就是 `课表&#10;课表`）。
      // 这里只补 `Text` 表达不了的两条信息：是个按钮、以及有没有选中。
      button: true,
      selected: on,
      child: GestureDetector(
        // opaque：整格都要能点，不能只点中图标那 20px
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelected(i),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(on ? dest.selectedIcon : dest.icon, size: 22, color: fg),
            const SizedBox(height: 3),
            Text(
              dest.label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: fg,
                fontWeight: on ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}