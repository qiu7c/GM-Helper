import 'package:flutter/material.dart';

import '../models/course.dart';
import '../models/period_time.dart';
import 'app_theme.dart';

/// 顶部那条实时状态：「正在上 XX · 还有 25 分钟下课」/「下一节 14:00 XX」。
///
/// 调用方只在「显示的就是本周」时才挂上来 —— 翻到别的周时不该说"现在"。
/// 时间由外面传进来（课表页有个 20 秒的时钟在推它），这个组件自己不留状态。
///
/// 布局是三栏：左边一块状态徽标（图标放在圆角色块里，一眼能看出在上的还是
/// 下一节），中间课程名 + 教室，右边下课/上课时间配一句还剩多久。正在上课时
/// 卡片底部还压一条进度条——「还剩 25 分钟」是数字，进度条才是感觉。
/// 没课的那条路径退化成一行，不摆空的时间列。
///
/// **它现在住在玻璃顶栏的 `AppBar.bottom` 里**，所以必须是个
/// [PreferredSizeWidget] —— `AppBar` 要在建的时候就问出这块有多高。
class NowStatusBar extends StatelessWidget implements PreferredSizeWidget {
  /// 本周的课（调用方已经按周过滤过）
  final List<Course> courses;

  /// 当前时刻，由外面的时钟驱动
  final DateTime now;

  /// 决定左侧那列时间用哪个校区的作息
  final String? campusId;

  const NowStatusBar({
    super.key,
    required this.courses,
    required this.now,
    this.campusId,
  });

  // 下面三个高度是从布局里算出来的，改布局就得跟着改。
  //
  // ⚠ 去掉卡片底色和描边之后这三个数**全变了**（原来是 76 / 79 / 56）：
  //    现在没有外边距 8+8 了，只剩内边距 8+8。
  //  - 上课中 / 下一节：内边距 8+8 + 内容 39.6（中间那列最高：bodyLarge
  //    15×1.4 = 21.0，加 3 的间隔，加 bodySmall 12×1.3 = 15.6；左边那个
  //    38×38 的图标块**不是**最高的）= 55.6，取 56 留 0.4 给 Skia 的定点舍入。
  //  - 上课中再加进度条那一行：3 的间隔 + 3 的条 = 61.6，取 62。
  //  - 一行版：8+8 + 内容 18（图标）= 34。
  static const double _cardHeight = 56;
  static const double _cardProgressHeight = 62;
  static const double _doneHeight = 34;

  @override
  Size get preferredSize => Size.fromHeight(_resolve().height);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = _resolve();
    if (state.kind == _Kind.none) return const SizedBox.shrink();

    final Widget body = switch (state.kind) {
      _Kind.current => _card(
          theme: theme,
          slot: state.current!,
          accent: true,
          icon: Icons.play_arrow_rounded,
          big: state.current!.time.endText,
          small: '还剩 ${state.current!.time.endMin - _nowMin} 分钟',
          progress: state.progress,
        ),
      _Kind.next => _card(
          theme: theme,
          slot: state.next!,
          accent: false,
          icon: Icons.schedule_rounded,
          big: state.next!.time.startText,
          small: _etaText(state.next!.time.startMin - _nowMin),
        ),
      _Kind.done => _doneRow(theme, state.slots.last.time.endText),
      _Kind.none => const SizedBox.shrink(),
    };

    // 高度由自己声明，所以这里**强制**渲染高度等于声明高度。上面那三个常量必须
    // 跟实际内容对得上 —— `Column(mainAxisSize: min)` 是**顶对齐**的，声明矮了
    // 不会"居中"，溢出的部分会从**底边**顶出去，而底边正好是进度条待的地方。
    // 所以常量是量出来的，不是估的。
    //
    // ClipRect 兜的是另一回事：用户把系统字号调到 1.2 倍以上时内容会真的超过声明
    // 高度（那几个常量没跟着 textScaler 走——AppBar 问 preferredSize 时拿不到
    // context），那时宁可裁掉也不要糊出框外。
    return SizedBox(
      height: state.height,
      child: ClipRect(child: body),
    );
  }

  int get _nowMin => now.hour * 60 + now.minute;

  /// 当前该显示哪一档。
  ///
  /// `preferredSize` 和 `build` **共用这一个**，是这套写法的关键：两处各算一遍
  /// 迟早会算出两个高度，而声明高度和渲染高度对不上就是一条缝或者一次裁切。
  _Now _resolve() {
    final slots = <_Slot>[];
    for (final c in courses.where((c) => c.day == now.weekday)) {
      final t = PeriodTime.of(campusId, c.period);
      if (t != null) slots.add(_Slot(c, t));
    }
    // 今天没课就整条不显示，免得天天占着一行说废话
    if (slots.isEmpty) return const _Now._none();
    slots.sort((a, b) => a.time.startMin.compareTo(b.time.startMin));

    _Slot? current;
    _Slot? next;
    for (final s in slots) {
      if (s.time.containsMinute(_nowMin)) {
        current ??= s;
      } else if (s.time.startMin > _nowMin) {
        next ??= s;
      }
    }

    if (current != null) {
      final span = current.time.endMin - current.time.startMin;
      final done = _nowMin - current.time.startMin;
      return _Now(
        kind: _Kind.current,
        current: current,
        slots: slots,
        progress: span <= 0 ? 0.0 : (done / span).clamp(0.0, 1.0).toDouble(),
      );
    }
    if (next != null) {
      return _Now(kind: _Kind.next, next: next, slots: slots);
    }
    return _Now(kind: _Kind.done, slots: slots);
  }

  static String _room(Course c) =>
      c.room.trim().isEmpty ? '未填教室' : c.room.trim();

  /// 上课中 / 下一节共用的一行。
  ///
  /// **没有卡片底色、也没有描边** —— 它和顶栏是同一块玻璃。这一版要拆掉的正是
  /// "状态卡自己是一张卡、顶栏是另一块"那种分层感。
  ///
  /// 强调只靠**颜色**：正在上课用 [AppTheme.accent]（淡红）点亮图标底、下课时间
  /// 和下面那条进度条；"下一节"保持灰阶。全 App 上色的地方就这一处和课表里
  /// "今天"那一列。
  Widget _card({
    required ThemeData theme,
    required _Slot slot,
    required bool accent,
    required IconData icon,
    required String big,
    required String small,
    double? progress,
  }) {
    final scheme = theme.colorScheme;
    final mark = accent ? AppTheme.accent : scheme.onSurfaceVariant;
    final subFg = scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  // 只有一层很淡的强调色底，**不用实心色块** —— 实心块会把这块
                  // 玻璃又变成"一张卡"，正是要拆掉的那个观感
                  color: accent
                      ? AppTheme.accent.withOpacity(0.16)
                      : scheme.onSurface.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 22, color: mark),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(slot.course.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface)),
                    const SizedBox(height: 3),
                    Text(_room(slot.course),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            theme.textTheme.bodySmall?.copyWith(color: subFg)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(big,
                      style: theme.textTheme.headlineSmall?.copyWith(
                          fontSize: 19,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                          color: accent ? AppTheme.accent : scheme.onSurface)),
                  const SizedBox(height: 3),
                  Text(small,
                      style:
                          theme.textTheme.labelMedium?.copyWith(color: subFg)),
                ],
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 3),
            // 圆角靠 ClipRRect：LinearProgressIndicator 自己是方的，
            // 一条方头细线压在这块玻璃上很硬
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                backgroundColor: scheme.onSurface.withOpacity(0.10),
                color: AppTheme.accent,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 今天的课全上完了：没有紧迫信息，就别摆那个时间列了，收敛成一行。
  ///
  /// 同样**不要**底色和描边，理由见 [_card]。
  Widget _doneRow(ThemeData theme, String lastEnd) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
      child: Row(
        children: [
          Icon(Icons.done_all_rounded, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '今天的课都上完了，最后一节 $lastEnd 下课',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  static String _etaText(int minutes) {
    if (minutes <= 1) return '马上开始';
    if (minutes < 60) return '$minutes 分钟后';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '$h 小时后' : '$h 小时 $m 分钟后';
  }
}

/// 当前该显示哪一档
enum _Kind { none, current, next, done }

/// `_resolve()` 的结果：既是要画什么，也是这块该有多高。
class _Now {
  const _Now({
    required this.kind,
    this.current,
    this.next,
    this.slots = const [],
    this.progress,
  });

  const _Now._none()
      : kind = _Kind.none,
        current = null,
        next = null,
        slots = const [],
        progress = null;

  final _Kind kind;
  final _Slot? current;
  final _Slot? next;
  final List<_Slot> slots;
  final double? progress;

  double get height => switch (kind) {
        // 写 0.0 不写 0：int 字面量在 double 上下文里是合法的，但这里没必要
        // 让读的人（和静态检查）去推一遍
        _Kind.none => 0.0,
        _Kind.current =>
          progress == null ? NowStatusBar._cardHeight : NowStatusBar._cardProgressHeight,
        _Kind.next => NowStatusBar._cardHeight,
        _Kind.done => NowStatusBar._doneHeight,
      };
}

class _Slot {
  final Course course;
  final PeriodTime time;
  _Slot(this.course, this.time);
}
