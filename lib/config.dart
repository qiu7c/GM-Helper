/// 全局配置：教务系统相关地址与学期设置
class AppConfig {
  /// 教务系统基础域名
  static const String jwHost = 'https://jw.gdgm.cn';

  /// 统一身份认证门户（登录入口）
  static const String portalUrl = 'https://eportal.gdgm.cn';

  /// 登录起始地址：访问教务系统会自动跳转到 SSO 登录页，
  /// 登录成功后又跳回教务系统主框架页。用它做登录起点，
  /// 便于通过最终 URL 判断是否登录成功。
  static const String loginStartUrl =
      '$jwHost/jsxsd/framework/xsMain.jsp';

  /// 学期理论课表接口
  static const String scheduleUrl = '$jwHost/jsxsd/xskb/xskb_list.do';

  /// 判定"已登录成功"的 URL 特征（跳回教务主框架即视为成功）
  static const List<String> loginSuccessMarkers = [
    '/jsxsd/framework/xsMain.jsp',
    '/jsxsd/framework/xsMain_new.jsp',
  ];

  /// 本学期第 1 周的周一日期，用于自动计算"当前第几周"。
  /// 需按实际校历修改。示例：2026-2027-1 学期。
  static DateTime termFirstMonday = DateTime(2026, 8, 31);

  /// 一天最多几个"大节"
  static const int periodCount = 6;

  /// 大节名称
  static const List<String> periodNames = [
    '第一大节',
    '第二大节',
    '第三大节',
    '第四大节',
    '第五大节',
    '第六大节',
  ];

  /// 大节对应的时间（可按学校作息调整，仅用于展示）
  static const List<String> periodTimes = [
    '08:20\n09:55',
    '10:15\n11:50',
    '14:00\n15:35',
    '15:55\n17:30',
    '18:30\n20:05',
    '20:15\n21:50',
  ];

  static const List<String> weekDayNames = [
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];
}
