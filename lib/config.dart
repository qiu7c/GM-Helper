/// 全局配置：教务系统相关地址与学期设置
class AppConfig {
  /// 教务系统基础域名
  static const String jwHost = 'https://jw.gdgm.cn';

  /// 统一身份认证门户
  static const String portalUrl = 'https://eportal.gdgm.cn';

  /// CAS 认证的 service 回调（编码后）
  static const String _service =
      'service=https%3A%2F%2Feportal.gdgm.cn%2Flogin'
      '%3Fservice%3Dhttps%3A%2F%2Feportal.gdgm.cn%2Fnew%2Findex.html%3Fbrowser%3Dno';

  /// 账号密码登录入口
  static const String loginPwdUrl =
      'https://sfrz.gdgm.cn/authserver/login?$_service';

  /// 企业微信扫码登录入口
  static const String loginQrUrl =
      'https://sfrz.gdgm.cn/authserver/login?display=qrLogin&$_service';

  /// 教务系统入口。门户登录成功后，用同一 WebView（已持有 SSO Cookie）访问
  /// 门户里的"教务系统"应用入口(appShow)，由它完成 SSO 握手并跳转到教务系统，
  /// 给 jw.gdgm.cn 种下会话，最终落到 xsMain.jsp。
  /// 直接访问 jw.gdgm.cn 不一定触发握手，必须走这个 appShow 入口。
  static const String jwEntryUrl =
      '$portalUrl/appShow?appId=5759540940956162';

  /// 教务系统最终落地页（用于对照，不直接访问）
  static const String jwMainUrl = '$jwHost/jsxsd/framework/xsMain.jsp';

  /// 学期理论课表接口
  static const String scheduleUrl = '$jwHost/jsxsd/xskb/xskb_list.do';

  /// 更新清单地址，指向**公开的分发仓**（源码仓是私有的，App 永远不碰它）。
  ///
  /// 写死在 `releases/latest/download/` 下：这个路径永远解析到「最新一次正式
  /// release」，所以不用随版本号改。清单内容形如：
  /// `{"version":"2.1.0","versionCode":11,"apk":"...","ipa":"..."}`
  ///
  /// 注意 release 不能勾成 prerelease / draft，否则 `latest` 不会指向它。
  static const String updateManifestUrl =
      'https://github.com/qiu7c/GMPluse-Release'
      '/releases/latest/download/latest.json';

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

  /// 各校区 kbjcmsid（时间模式 id），来自教务课表页的下拉选项
  static const String campusTianhe = '3589FB3E8AD246BCBAD7BB5C8710D078';
  static const String campusLiwan = '0A10E5C18E814AEAA9456E91A7092394';
  static const String campusBaiyun = '29637FA5710B46F3B01242A09D7E9CCD';

  /// 各校区大节时间（每格 = 首小节开始 ~ 次小节结束）。
  /// 荔湾校区无第六大节，用空字符串占位。
  static const Map<String, List<String>> campusPeriodTimes = {
    campusTianhe: [
      '08:00\n09:40',
      '10:00\n11:40',
      '14:00\n15:35',
      '15:55\n17:30',
      '18:50\n20:30',
      '20:40\n21:25',
    ],
    campusBaiyun: [
      '08:30\n10:05',
      '10:25\n12:00',
      '14:00\n15:35',
      '15:55\n17:30',
      '19:00\n20:35',
      '20:40\n21:25',
    ],
    campusLiwan: [
      '08:30\n10:05',
      '10:25\n12:00',
      '14:00\n15:35',
      '15:55\n17:30',
      '19:00\n20:35',
      '', // 荔湾无第六大节
    ],
  };

  /// 默认时间（校区未知时用天河）
  static const List<String> periodTimes = [
    '08:00\n09:40',
    '10:00\n11:40',
    '14:00\n15:35',
    '15:55\n17:30',
    '18:50\n20:30',
    '20:40\n21:25',
  ];

  /// 取某校区某大节(1..6)的时间，无匹配则回退默认
  static String periodTime(String? campusId, int period) {
    final list = campusPeriodTimes[campusId] ?? periodTimes;
    if (period < 1 || period > list.length) return '';
    return list[period - 1];
  }

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
