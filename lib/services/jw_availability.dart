import 'package:dio/dio.dart';

import '../config.dart';

/// 教务系统"活着没有"。一次探测只会得到其中一个。
enum JwReach {
  /// 2xx：正常应答
  up,

  /// 3xx：会话失效时会跳到统一身份认证。**系统本身是活的。**
  loginRequired,

  /// 5xx：答了，但它自己报错（崩了 / 502 / 维护页）
  serverError,

  /// 根本没有应答：超时、连接被拒、DNS 失败
  unreachable,
}

/// 探教务系统的连通性，用来把"自己网络的问题"和"学校那边的问题"分开。
///
/// 为什么需要：课表抓不下来的时候，页面上原来只给得出「网络不可用 / 请求超时 /
/// 刷新失败」这三句 —— 都是从异常字符串里猜的。可实际上常见得多的原因是学校那边：
/// 教务系统崩了，或者它每天有几段维护时间关闭。这两种情况**用户能做的事完全不同**：
///
///   * 自己网络的问题 → 该去检查 wifi；
///   * 学校的问题     → 做什么都没用，等着就行。
///
/// 所以"已经失败"之后补一次探测（成功路径上一次都不探，不拖慢打开课表），
/// 判据集中在 [schoolLooksDown]。
class JwAvailability {
  const JwAvailability._();

  /// 探测结果的复用窗口。
  ///
  /// 探测只在失败之后做，但用户会连点重试 —— 不缓存就等于拿学校服务器当压测对象，
  /// 而且每次都要多等一个来回。
  static const Duration _reuse = Duration(seconds: 20);

  /// 探针的超时比正常请求短得多：它只回答"连不连得上"，不需要等页面下载完。
  /// 失败之后用户已经在等了，这里每多一秒都是从他身上拿的。
  static const Duration _timeout = Duration(seconds: 4);

  static JwReach? _cachedJw;
  static bool? _cachedPortalAlive;
  static DateTime? _cachedAt;

  static Future<JwReach> _probe(String url) async {
    final dio = Dio(BaseOptions(
      // 要**看见** 3xx：跟着跳到登录页就变成 200，分不出"会话失效"和"系统活着"
      followRedirects: false,
      // 连 4xx/5xx 也不许抛异常 —— 状态码是这里唯一的信息，抛了就什么都没有了
      validateStatus: (_) => true,
      connectTimeout: _timeout,
      receiveTimeout: _timeout,
      // 页面是 HTML：别让 dio 去按 JSON 解，解失败会被当成"连不上"
      responseType: ResponseType.plain,
      headers: {'User-Agent': AppConfig.userAgent},
    ));
    try {
      final r = await dio.get(url);
      final s = r.statusCode ?? 0;
      if (s >= 500) return JwReach.serverError;
      if (s >= 300) return JwReach.loginRequired;
      if (s >= 200) return JwReach.up;
      return JwReach.serverError; // 1xx 之类不该出现，保守当成"有问题"
    } catch (_) {
      return JwReach.unreachable;
    }
  }

  /// 判据。**纯函数**，抽出来是为了能测：真去 ping 学校的测试在 CI 里跑不了，
  /// 而这里"两个都连不上时该赖谁"的组合逻辑才是容易写错的地方。
  ///
  /// [portalAlive] 传学校门户（eportal）是否答得上 —— 它是用来区分"学校的网不通"
  /// 和"只有教务不在"的参照物。
  static bool schoolLooksDown({
    required JwReach jw,
    required bool portalAlive,
  }) {
    // 它自己回了 5xx：直接证据，跟门户怎么样无关
    if (jw == JwReach.serverError) return true;
    // 教务不答、而学校门户答得上 → 用户的网是通的，是教务自己不在
    if (jw == JwReach.unreachable) return portalAlive;
    // 教务答得上（200，或者跳到登录页）→ 它活着，这次失败是别的原因
    return false;
  }

  /// 现在是不是"学校那边的事"。会自己做 20 秒缓存。
  static Future<bool> schoolLooksDownNow() async {
    final at = _cachedAt;
    if (at != null &&
        _cachedJw != null &&
        _cachedPortalAlive != null &&
        DateTime.now().difference(at) < _reuse) {
      return schoolLooksDown(
          jw: _cachedJw!, portalAlive: _cachedPortalAlive!);
    }

    // 两个探测**并发**。串行的话最坏要等两个超时，而这两个超时都是用户盯着
    // 「刷新失败」多等的。并发之后最坏就是一个 _timeout。
    final r = await Future.wait([
      _probe(AppConfig.jwMainUrl),
      _probe(AppConfig.portalUrl),
    ]);

    _cachedJw = r[0];
    _cachedPortalAlive = r[1] != JwReach.unreachable;
    _cachedAt = DateTime.now();
    return schoolLooksDown(jw: _cachedJw!, portalAlive: _cachedPortalAlive!);
  }
}