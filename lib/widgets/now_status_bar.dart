import 'package:flutter/material.dart';

import '../models/course.dart';
import '../models/period_time.dart';

/// 顶部那条实时状态：「正在上 XX · 还有 25 分钟下课」/「下一节 14:00 XX」。
///
/// 调用方只在「显示的就是本周」时才挂上来 —— 翻到别的周时不该说"现在"。
/// 时间由外面传进来（课表页有个 20 秒的时钟在推它），这个组件自己不留状态。
///
/// 布局是三栏：左边一块状态徽标（图标放在圆角色块里，一眼能看出在上的还是
/// 下一节），中间课程名 + 教室，右边下课/上课时间配一句还剩多久。正在上课时
/// 卡片底部还压一条进度条——「还剩 25 分钟」是数字，进度条才是感觉。
/// 没课的那条路径退化成一行，不摆空的时间列。
class NowStatusBar extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final nowMin = now.hour * 60 + now.minute;

    final slots = <_Slot>[];
    for (final c in courses.where((c) => c.day == now.weekday)) {
      final t = PeriodTime.of(campusId, c.period);
      if (t != null) slots.add(_Slot(c, t));
    }
    // 今天没课就整条不显示，免得天天占着一行说废话
    if (slots.isEmpty) return const SizedBox.shrink();
    slots.sort((a, b) => a.time.startMin.compareTo(b.time.startMin));

    _Slot? current;
    _Slot? next;
    for (final s in slots) {
      if (s.time.containsMinute(nowMin)) {
        current ??= s;
      } else if (s.time.startMin > nowMin) {
        next ??= s;
      }
    }

    if (current != null) {
      final span = current.time.endMin - current.time.startMin;
      final done = nowMin - current.time.startMin;
      return _card(
        scheme: scheme,
        accent: true,
        icon: Icons.play_arrow_rounded,
        title: current.course.name,
        subtitle: _room(current.course),
        // 右边大字给**下课时间**：上课时最想知道的其实是几点能走
        big: current.time.endText,
        small: '还剩 ${current.time.endMin - nowMin} 分钟',
        progress: span <= 0 ? 0.0 : (done / span).clamp(0.0, 1.0).toDouble(),
      );
    }

    if (next != null) {
      return _card(
        scheme: scheme,
        accent: false,
        icon: Icons.schedule_rounded,
        title: next.course.name,
        subtitle: _room(next.course),
        big: next.time.startText,
        small: _etaText(next.time.startMin - nowMin),
      );
    }

    return _doneRow(scheme, slots.last.time.endText);
  }

  static String _room(Course c) =>
      c.room.trim().isEmpty ? '未填教室' : c.room.trim();

  /// 上课中 / 下一节共用的一张卡。accent 为真时用主色强调（正在上）。
  Widget _card({
    required ColorScheme scheme,
    required bool accent,
    required IconData icon,
    required String title,
    required String subtitle,
    required String big,
    required String small,
    double? progress,
  }) {
    final bg = accent ? scheme.primaryContainer : scheme.surfaceContainerLow;
    final onCard = accent ? scheme.onPrimaryContainer : scheme.onSurface;
    final subFg = accent
        ? scheme.onPrimaryContainer.withOpacity(0.72)
        : scheme.onSurfaceVariant;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      // 让底部那条进度条能贴着圆角裁掉，而不是悬在卡片里
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        // 强调态本来就有底色，再描一圈反而显脏
        border: accent ? null : Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: accent ? scheme.primary : scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon,
                      size: 22,
                      color: accent
                          ? scheme.onPrimary
                          : scheme.onSecondaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: onCard)),
                      const SizedBox(height: 3),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: subFg)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(big,
                        style: TextStyle(
                            fontSize: 19,
                            height: 1.1,
                            fontWeight: FontWeight.w700,
                            color: onCard)),
                    const SizedBox(height: 3),
                    Text(small,
                        style: TextStyle(fontSize: 11, color: subFg)),
                  ],
                ),
              ],
            ),
          ),
          if (progress != null)
            LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: scheme.onPrimaryContainer.withOpacity(0.18),
              color: scheme.primary,
            ),
        ],
      ),
    );
  }

  /// 今天的课全上完了：没有紧迫信息，就别摆那个时间列了，收敛成一行
  Widget _doneRow(ColorScheme scheme, String lastEnd) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.done_all_rounded, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '今天的课都上完了，最后一节 $lastEnd 下课',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
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

class _Slot {
  final Course course;
  final PeriodTime time;
  _Slot(this.course, this.time);
}
