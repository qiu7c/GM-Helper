/// 全局配置：教务系统相关地址与学期设置
class AppConfig {
  /// 教务系统基础域名
  static const String jwHost = 'https://jw.gdgm.cn';

  /// 统一身份认证门户
  static const String portalUrl = 'https://eportal.gdgm.cn';

  /// 统一身份认证登录入口（CAS）。用户在这里输账号密码。
  /// 登录成功后 CAS 会带票据跳回 eportal 门户首页。
  static const String loginStartUrl =
      'https://sfrz.gdgm.cn/authserver/login'
      '?service=https%3A%2F%2Feportal.gdgm.cn%2Flogin'
      '%3Fservice%3Dhttps%3A%2F%2Feportal.gdgm.cn%2Fnew%2Findex.html%3Fbrowser%3Dno';

  /// 教务系统入口。门户登录成功后，用同一 WebView（已持有 SSO Cookie）
  /// 访问它，CAS 会自动放行并给教务系统种下会话，从而"同一浏览器已登录"。
  static const String jwEntryUrl = '$jwHost/jsxsd/framework/xsMain.jsp';

  /// 学期理论课表接口
  static const String scheduleUrl = '$jwHost/jsxsd/xskb/xskb_list.do';

  /// 判定"门户已登录"的 URL 特征（CAS 登录成功后落在 eportal 首页）
  static const List<String> portalSuccessMarkers = [
    'eportal.gdgm.cn/new/index',
    'eportal.gdgm.cn/index',
  ];

  /// 判定"教务系统已登录"的 URL 特征（进入教务主框架）
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
