import 'package:flutter/material.dart';

import 'app_theme.dart';
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
/// 几个刻意的选择：
///
///  * **用 `GestureDetector` 不用 `InkWell`**。`InkWell` 找的是最近的那个
///    `Material`，在这个位置就是壳 Scaffold 的 —— 而它画在底栏**下面**，
///    水波纹会被玻璃挡得一干二净，白花一次绘制。反馈交给滑动的胶囊。
///  * **补了 `Semantics`**。`NavigationBar` 自带无障碍语义，换成手搓的就没有了，
///    读屏会只念出"课表 我的"两个孤零零的词。
///  * 颜色全部取自 `colorScheme`，不再出现 `Colors.grey` 这类硬编码。
class GlassNavBar extends StatelessWidget {
  const GlassNavBar({
    super.key,
    required this.index,
    required this.onSelected,
  });

  final int index;
  final ValueChanged<int> onSelected;

  /// 玻璃本体的高度。**不含**外面的左右留白和底部安全区（那些在 home_shell）
  static const double height = 64;

  /// 胶囊离玻璃边缘的间距
  static const double _pillInset = 6;

  /// 滑过去的时长。太快看不出在动，太慢会拖在手指后面
  static const Duration _slide = Duration(milliseconds: 260);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return GlassPanel(
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      // Border.all 是**均匀**边框，所以可以和圆角共存
      // （只有底边那种不均匀的会被 BoxDecoration 断言拦下）
      border: Border.all(color: scheme.outlineVariant, width: 0.5),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            // 胶囊衬在最底下
            AnimatedAlign(
              duration: _slide,
              curve: Curves.easeOutCubic,
              alignment: index == 0
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: FractionallySizedBox(
                widthFactor: 1 / _dests.length,
                heightFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.all(_pillInset),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(
                        AppTheme.radiusLg - _pillInset,
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
                  Expanded(child: _item(context, theme, i)),
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
    final fg = on ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: on,
      label: dest.label,
      child: GestureDetector(
        // opaque：整格都要能点，不能只点中图标那 22px
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
