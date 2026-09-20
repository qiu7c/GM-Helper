import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 课程备注：按「课程名」长期保存，跨学期/周次都生效。
/// 单例 + ValueNotifier，改动后课表页自动刷新角标。
class CourseNotes {
  CourseNotes._();
  static final CourseNotes instance = CourseNotes._();

  static const _key = 'course_notes';

  /// courseName -> note
  final Map<String, String> _notes = {};

  /// 备注变更通知（课表页监听后重绘）
  final ValueNotifier<int> revision = ValueNotifier(0);

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _notes
          ..clear()
          ..addAll(map.map((k, v) => MapEntry(k, v.toString())));
      } catch (_) {}
    }
    _loaded = true;
  }

  String? noteOf(String courseName) {
    final v = _notes[courseName];
    return (v == null || v.isEmpty) ? null : v;
  }

  bool hasNote(String courseName) => noteOf(courseName) != null;

  Future<void> setNote(String courseName, String note) async {
    final trimmed = note.trim();
    if (trimmed.isEmpty) {
      _notes.remove(courseName);
    } else {
      _notes[courseName] = trimmed;
    }
    await _persist();
    revision.value++;
  }

  Future<void> clearNote(String courseName) => setNote(courseName, '');

  Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(_notes));
  }
}
