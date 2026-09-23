import '../config.dart';

/// 一个大节的上课时间段，来自 AppConfig 里各校区的固定作息表。
///
/// 存成"从 0 点起的分钟数"，方便跟 DateTime 直接比大小；
/// 原始格式是 `'08:00\n09:40'` 这种字符串。
class PeriodTime {
  /// 第几大节，1..6
  final int period;

  /// 开始 / 结束（从 0 点起的分钟数）
  final int startMin;
  final int endMin;

  const PeriodTime(this.period, this.startMin, this.endMin);

  /// 取某校区某大节的时间。该校区没这一节（荔湾没有第六大节）时返回 null。
  static PeriodTime? of(String? campusId, int period) {
    final raw = AppConfig.periodTime(campusId, period);
    if (raw.isEmpty) return null;
    final parts = raw.split('\n');
    if (parts.length < 2) return null;
    final s = _parse(parts[0]);
    final e = _parse(parts[1]);
    if (s == null || e == null) return null;
    return PeriodTime(period, s, e);
  }

  static int? _parse(String hhmm) {
    final p = hhmm.trim().split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  /// "08:00"
  String get startText => _fmt(startMin);

  /// "09:40"
  String get endText => _fmt(endMin);

  static String _fmt(int min) =>
      '${(min ~/ 60).toString().padLeft(2, '0')}:'
      '${(min % 60).toString().padLeft(2, '0')}';

  /// 某个时刻在这节课中间吗（左闭右开，下课那一分钟不算还在上）
  bool containsMinute(int minute) =>
      minute >= startMin && minute < endMin;
}
