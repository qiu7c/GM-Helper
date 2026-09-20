/// 一节课的数据模型
class Course {
  /// 课程名称，如"数据库原理及应用"
  final String name;

  /// 教师，如"董加敏"
  final String teacher;

  /// 教室，如"实803"
  final String room;

  /// 教学班/上课信息，如"天河足球020102"
  final String teachingClass;

  /// 原始周次(节次)字符串，如 "3-6,10-19(周)[01-02节]"
  final String rawWeeks;

  /// 解析后的上课周列表，如 [3,4,5,6,10,...,19]
  final List<int> weeks;

  /// 星期几：1=周一 ... 7=周日
  final int day;

  /// 第几大节：1..6
  final int period;

  /// 小节区间描述，如 "01-02节"
  final String sectionRange;

  const Course({
    required this.name,
    required this.teacher,
    required this.room,
    required this.teachingClass,
    required this.rawWeeks,
    required this.weeks,
    required this.day,
    required this.period,
    required this.sectionRange,
  });

  /// 该课程是否在指定周上课
  bool activeInWeek(int week) => weeks.contains(week);

  Map<String, dynamic> toJson() => {
        'name': name,
        'teacher': teacher,
        'room': room,
        'teachingClass': teachingClass,
        'rawWeeks': rawWeeks,
        'weeks': weeks,
        'day': day,
        'period': period,
        'sectionRange': sectionRange,
      };

  factory Course.fromJson(Map<String, dynamic> json) => Course(
        name: json['name'] ?? '',
        teacher: json['teacher'] ?? '',
        room: json['room'] ?? '',
        teachingClass: json['teachingClass'] ?? '',
        rawWeeks: json['rawWeeks'] ?? '',
        weeks: (json['weeks'] as List?)?.map((e) => e as int).toList() ?? [],
        day: json['day'] ?? 1,
        period: json['period'] ?? 1,
        sectionRange: json['sectionRange'] ?? '',
      );
}

/// 一次课表查询的结果：课程列表 + 页面可选项（学期/周次/校区）
class ScheduleResult {
  final List<Course> courses;
  final List<SelectOption> terms; // 学年学期
  final List<SelectOption> weeks; // 周次
  final List<SelectOption> campuses; // 时间模式(校区)
  final String? selectedTerm;
  final String? selectedWeek;
  final String? selectedCampus;
  final String remark; // 备注，如"军事技能 1-15周;"

  const ScheduleResult({
    required this.courses,
    this.terms = const [],
    this.weeks = const [],
    this.campuses = const [],
    this.selectedTerm,
    this.selectedWeek,
    this.selectedCampus,
    this.remark = '',
  });
}

/// 下拉框选项
class SelectOption {
  final String value;
  final String label;
  const SelectOption(this.value, this.label);
}

/// 学期日历信息，来自教务桌面页 .middletopleftrqbox：
/// 当前第几周、总周数、系统当前日期。由此推算学期第一周周一。
class TermCalendar {
  final int currentWeek;
  final int totalWeeks;
  final DateTime date; // 系统当前日期

  const TermCalendar({
    required this.currentWeek,
    required this.totalWeeks,
    required this.date,
  });

  /// 学期第 1 周的周一 = 当前日期所在周的周一 - (当前周-1)*7 天
  DateTime get firstMonday {
    final monday = date.subtract(Duration(days: date.weekday - 1));
    return DateTime(monday.year, monday.month, monday.day)
        .subtract(Duration(days: (currentWeek - 1) * 7));
  }
}
