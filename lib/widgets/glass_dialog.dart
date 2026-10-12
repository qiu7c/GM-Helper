import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'glass.dart';

// 全 App 的弹层（对话框 + 底部弹层）。
//
// **为什么不直接用 `showDialog` / `AlertDialog`：它们的"底"是一块不透明的纯色。**
// `AlertDialog` 取的是 `colorScheme` 里某个 `surfaceContainer*` 槽位 —— 压在一个
// 已经模糊的页面上，就是一块灰板。而弹层这个形态的意义恰恰是"浮在页面之上"，
// 一块纯色板表达的是"盖住"，不是"浮起"。
//
// 所以两件事都得自己画：
//
//  * **蒙层先模糊、再压暗。** `showDialog` 的 `barrierColor` 只能填纯色，想模糊
//    就只能绕到 `showGeneralDialog` 自己写 `pageBuilder` —— 这是必须换掉
//    `showDialog` 的根本原因，不是为了好看。
//  * **面板复用 `GlassPanel`**：和顶栏、底栏、底栏胶囊同一套材质，不是另做一套。
//
// 底部弹层那条路只能做到一半：`showModalBottomSheet` 不支持模糊蒙层，所以蒙层仍是
// 半透明纯色；但**面板**换成玻璃之后，透过去就是模糊后的页面，"那块纯色板"已经
// 不存在了 —— 用户看到的那块板就是玻璃本身。

/// 蒙层模糊半径。
///
/// 比玻璃那层（`AppTheme.glassBlur` = 30）**小**是故意的：蒙层是全屏的，半径 30
/// 等于每帧抓一整屏再糊一次，代价实打实。18 已经足够把底下的文字糊成色块 ——
/// 蒙层要的是"看不清内容"，不是"玻璃质感"。
const double _barrierBlur = 18;

/// 弹层的填充不透明度。
///
/// 比 [AppTheme.glassFill]（0.34）实不少。理由：玻璃下面那层是**模糊过的**，细节
/// 已经被抹平了，所以填充不需要靠"实"来保证可读 —— 但弹层里是**成段的文字**，
/// 不像底栏只有四个词，压在最不确定的底色上读起来会累。0.55 是这两者之间的取值：
/// 底下still能透出明暗层次（看得出是玻璃），字也站得住。
const double _fill = 0.55;

/// 一个玻璃对话框。
///
/// 用法和 `AlertDialog` 基本一致，只是外面套了"模糊蒙层 + 玻璃面板"。
Future<T?> showGlassDialog<T>({
  required BuildContext context,
  Widget? title,
  Widget? content,
  List<Widget>? actions,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // 蒙层由 `_GlassDialog` 自己画，这里必须透明 —— 给个纯色就把模糊盖掉了
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 170),
    pageBuilder: (_, __, ___) => _GlassDialog(
      title: title,
      content: content,
      actions: actions,
    ),
    transitionBuilder: (context, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        // 0.94 → 1 的缩放：弹层是"弹"出来的，不是突然出现
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// 参数刻意对齐 `AlertDialog` 的常用三个（title/content/actions，title 也是 Widget
/// 而不是 String），这样把调用点从 `showDialog` 换过来时，只要把 `AlertDialog(...)`
/// 换成这里的三个具名参数就行，不用重排内部结构。
class _GlassDialog extends StatelessWidget {
  const _GlassDialog({this.title, this.content, this.actions});

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasActions = actions != null && actions!.isNotEmpty;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 先模糊，再压暗。**顺序不能反** —— 先压暗再模糊，模糊的是一块半透明色，
        // 等于白糊。
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: _barrierBlur, sigmaY: _barrierBlur),
          child: ColoredBox(color: Colors.black.withOpacity(0.26)),
        ),
        Center(
          // 整块面板可滚：内容长的时候（比如课表变化清单）不至于溢出屏幕
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: GlassPanel(
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                fillOpacity: _fill,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(24, 22, 24, hasActions ? 14 : 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (title != null)
                        DefaultTextStyle(
                          style: theme.textTheme.titleMedium!,
                          child: title!,
                        ),
                      if (content != null)
                        Padding(
                          padding: EdgeInsets.only(top: title == null ? 0 : 12),
                          child: DefaultTextStyle(
                            style: theme.textTheme.bodyMedium!.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            child: content!,
                          ),
                        ),
                      if (hasActions)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            children: actions!,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 玻璃底部弹层。用法和 `showModalBottomSheet` 一样：`builder` 返回面板内容，
/// 面板本身（圆角、拖动条、玻璃）由这里提供。
Future<T?> showGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: isScrollControlled,
    // `showModalBottomSheet` 没法模糊蒙层，这里只能给半透明纯色。这是这条路唯一
    // 没做到"模糊"的地方，如实记着。
    barrierColor: Colors.black.withOpacity(0.24),
    // 拖动条自己画进玻璃里。系统的那个画在面板**外面** —— 背景透明之后它会变成
    // 悬空的一条线。
    showDragHandle: false,
    builder: (ctx) => GlassSheet(child: Builder(builder: builder)),
  );
}

/// 玻璃面板做的底部弹层本体。
///
/// 四边都留出一点边距（含底部安全区），让它明确是"浮起来的一块"，而不是贴满下半屏
/// 的一张纸 —— 后者和"玻璃"是矛盾的：贴满边的玻璃没有轮廓，读起来就是换了颜色的底。
class GlassSheet extends StatelessWidget {
  const GlassSheet({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        10,
        0,
        10,
        10 + MediaQuery.of(context).padding.bottom,
      ),
      child: GlassPanel(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        fillOpacity: _fill,
        child: Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface
                      .withOpacity(dark ? 0.32 : 0.20),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}