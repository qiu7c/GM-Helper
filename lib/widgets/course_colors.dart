import 'package:flutter/material.dart';

/// 按课程名生成稳定的柔和配色，让同名课颜色一致
class CourseColors {
  static const List<Color> _palette = [
    Color(0xFF5B8FF9),
    Color(0xFF61DDAA),
    Color(0xFFF6BD16),
    Color(0xFFFF9D4D),
    Color(0xFF7262FD),
    Color(0xFF78D3F8),
    Color(0xFF9661BC),
    Color(0xFFF6903D),
    Color(0xFF008685),
    Color(0xFFF08BB4),
    Color(0xFFE8684A),
    Color(0xFF6DC8EC),
  ];

  static Color of(String name) {
    if (name.isEmpty) return _palette.first;
    var hash = 0;
    for (final code in name.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return _palette[hash % _palette.length];
  }
}
