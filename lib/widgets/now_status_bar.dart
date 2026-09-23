import 'package:flutter/material.dart';

import '../models/course.dart';
import '../models/period_time.dart';

/// 顶部那条实时状态：「正在上 XX · 还有 25 分钟下课」/「下一节 14:00 XX」。
///
/// 调用方只在「显示的就是本周」时才挂上来 —— 翻到别的周时不该说"现在"。
/// 时间由外面传进来（课表页有个 30 秒的时钟在推它），这个组件自己不留状态。
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

    final live = current != null;
    final IconData icon;
    final String title;
    final String sub;

    if (current != null) {
      icon = Icons.play_circle_outline;
      title = '正在上 · ${current.course.name}';
      sub = _join([
        current.course.room,
        '${current.time.endText} 下课',
        '还有 ${current.time.endMin - nowMin} 分钟',
      ]);
    } else if (next != null) {
      icon = Icons.schedule;
      title = '下一节 ${next.time.startText} · ${next.course.name}';
      sub = _join([
        next.course.room,
        _etaText(next.time.startMin - nowMin),
      ]);
    } else {
      icon = Icons.check_circle_outline;
      title = '今天的课都上完了';
      sub = '';
    }

    final bg = live ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final fg = live ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;

    return Material(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600, color: fg),
                  ),
                  if (sub.isNotEmpty)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: fg),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _join(List<String> parts) =>
      parts.where((p) => p.trim().isNotEmpty).join(' · ');

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
