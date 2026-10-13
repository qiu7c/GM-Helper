import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'app_info.dart';

/// 一个新版本的信息，来自分发仓里的 latest.json
class UpdateInfo {
  final String version;
  final int? versionCode;
  final String apkUrl;
  final String ipaUrl;
  final String notes;

  /// 这份清单是从哪条加速线路拿到的（null = GitHub 直连）。
  ///
  /// 下载走**同一条**：能取到清单已经证明这条线路对得上这个仓，比另挑一条瞎试靠谱。
  final String? routePrefix;

  /// 清单里自带的加速前缀。分发仓随时可以改这个数组，**不用发新版**给用户 ——
  /// 第三方加速站是会倒闭的，能把线路做成可远程更新的，就别焊死在包里。
  final List<String> mirrors;

  const UpdateInfo({
    required this.version,
    this.versionCode,
    this.apkUrl = '',
    this.ipaUrl = '',
    this.notes = '',
    this.routePrefix,
    this.mirrors = const [],
  });
}

/// 更新检查。
///
/// 读的是**公开分发仓**里的 latest.json —— 源码仓是私有的，App 永远不碰它，
/// 所以这个请求不带任何凭证（往 App 里塞 token 比公开源码还糟）。
///
/// 一切失败都当成"没有更新"：网络不通、分发仓还没建、json 坏了、GitHub 抽风，
/// 一律静默返回 null，绝不能因为检查更新失败就打扰用户。
///
/// **国内线路**是这一版新加的。分发仓在 GitHub，国内直连经常几十 KB/s 甚至超时，
/// 所以清单和安装包都走一层加速站。做法是**并发**试所有线路、第一个拿到真东西的
/// 胜出：清单只有几百字节，同时开几条的代价远小于一条一条等超时（最坏几十秒）。
class UpdateService {
  UpdateService._();

  /// 内置加速前缀。**顺序 = 优先级**，这份顺序是**实测**排出来的
  /// （脚本挨个拉本仓的 latest.json + 25MB 安装包的前 1MB，量的是真实速度）：
  ///
  ///   gh-proxy.com   879 KB/s   清单 ✓  安装包 ✓
  ///   gh.llkk.cc     415 KB/s   清单 ✓  安装包 ✓
  ///   ghfast.top     289 KB/s   清单 ✓  安装包 ✓
  ///   ghproxy.net    147 KB/s   清单 ✓  安装包 ✓
  ///
  /// 同批测的还有：ghproxy.cc / hub.gitmirror.com / github.moeyy.xyz /
  /// mirror.ghproxy.com（连不上）、ghproxy.homeboyc.cn（403），以及
  /// **gitproxy.click** —— 它清单给得出来，安装包却返回 200 + 一页 HTML。
  /// 最后这个正是 [looksLikePackageBytes] 要挡的东西：不挡的话浏览器会把那页
  /// HTML 存成 `xxx.apk`，用户装的时候才炸，而且完全看不出问题在哪。
  ///
  /// 第三方加速站生命周期都不长，挂了不要紧：**并发**试用，挂掉的线路只是白试一次，
  /// 不影响其它线路，最后还有 GitHub 直连兜底。
  static const List<String> builtinMirrors = <String>[
    'https://gh-proxy.com/',
    'https://gh.llkk.cc/',
    'https://ghfast.top/',
    'https://ghproxy.net/',
  ];

  /// 清单超时。比原来短：并发试的时候不需要给单条那么久。
  static const Duration _manifestTimeout = Duration(seconds: 6);

  /// 安装包预检超时（只读头 64KB）
  static const Duration _probeTimeout = Duration(seconds: 5);

  static const String _kMirrors = 'update_mirrors_v1';
  static const String _kAnnounced = 'update_announced_version';

  /// 预检通过的下载地址，按**原始地址**缓存。用户在设置页和启动弹窗里点的是同一个
  /// 版本，不该两次都去试。
  static final Map<String, String> _resolved = {};

  static Dio _dio(Duration t) => Dio(BaseOptions(
        connectTimeout: t,
        receiveTimeout: t,
        // releases/latest/download/... 是 302 跳到 objects.githubusercontent.com，
        // 必须跟着走，否则拿到的是个空的重定向响应
        followRedirects: true,
        maxRedirects: 5,
      ));

  /// 所有候选线路：GitHub 直连 + 各加速前缀。**全部同时开**，谁先成谁赢。
  static List<({String url, String? prefix})> _routes(List<String> mirrors) => [
        (url: AppConfig.updateManifestUrl, prefix: null),
        for (final m in mirrors)
          (url: '$m${AppConfig.updateManifestUrl}', prefix: m),
      ];

  /// 取一份能用的清单（含它来自哪条线路），全都失败才返回 null。
  static Future<({Map<String, dynamic> json, String? prefix})?> _fetch() async {
    if (AppConfig.updateManifestUrl.isEmpty) return null;
    final routes = _routes(await _mirrors());
    final done = Completer<({Map<String, dynamic> json, String? prefix})?>();
    var pending = routes.length;

    void miss() {
      if (--pending == 0 && !done.isCompleted) done.complete(null);
    }

    for (final r in routes) {
      // 每条线路独立跑，互不等待；这条失败了只是少一个候选
      unawaited(() async {
        try {
          final resp = await _dio(_manifestTimeout).get<String>(
            r.url,
            options: Options(responseType: ResponseType.plain),
          );
          final raw = resp.data;
          // ⚠ 加速站挂掉时常返回一个 HTML 提示页（状态码还是 200），
          // 所以不能只看状态码。这里先按首个非空白字符挡一道，再按 JSON 内容挡一道。
          final looksJson =
              raw != null && raw.trimLeft().startsWith('{');
          final parsed = looksJson ? jsonDecode(raw) : null;
          if (done.isCompleted) return;
          if (parsed is Map &&
              (parsed['version'] ?? '').toString().isNotEmpty) {
            done.complete(
                (json: Map<String, dynamic>.from(parsed), prefix: r.prefix));
          } else {
            miss();
          }
        } catch (_) {
          if (!done.isCompleted) miss();
        }
      }());
    }
    return done.future;
  }

  /// 检查更新。有新版返回 [UpdateInfo]，否则（含一切失败）返回 null。
  static Future<UpdateInfo?> check() async {
    final hit = await _fetch();
    if (hit == null) return null;

    final map = hit.json;
    final info = UpdateInfo(
      version: (map['version'] ?? '').toString(),
      versionCode: int.tryParse((map['versionCode'] ?? '').toString()),
      apkUrl: (map['apk'] ?? '').toString(),
      ipaUrl: (map['ipa'] ?? '').toString(),
      notes: (map['notes'] ?? '').toString(),
      routePrefix: hit.prefix,
      mirrors: _stringList(map['mirrors']),
    );
    if (info.version.isEmpty) return null;
    if (!isNewer(info)) return null;

    // 记住分发仓给的线路，下次它们排在前面
    unawaited(_rememberMirrors(info.mirrors));
    return info;
  }

  /// 有新版才返回 true。优先比 versionCode（pubspec 里 `+` 后面那个数，单调递增），
  /// 拿不到再退回比 "2.10.1" 这种字符串。
  static bool isNewer(UpdateInfo info) {
    final cur = int.tryParse(AppInfo.buildNumber);
    if (info.versionCode != null && cur != null) {
      return info.versionCode! > cur;
    }
    return _compare(info.version, AppInfo.version) > 0;
  }

  /// 当前平台该下哪个包（**原始**地址，没套加速前缀）。iOS 是未签名 IPA，
  /// 下载后用 TrollStore 侧载。
  static String? downloadUrlFor(UpdateInfo info) {
    if (Platform.isIOS) return info.ipaUrl.isEmpty ? null : info.ipaUrl;
    if (Platform.isAndroid) return info.apkUrl.isEmpty ? null : info.apkUrl;
    return null;
  }

  /// 真正交给浏览器的下载地址：套上**预检通过**的加速前缀。
  ///
  /// 预检不是多此一举：加速站返回错误页时是 `200` + HTML，浏览器会把那个 HTML 存成
  /// `xxx.apk`，用户装的时候才炸，而且根本看不出问题在哪。这里只读头 64KB，检查它
  /// 开头是不是 ZIP 魔数（APK 和 IPA 都是 zip），不是就换下一条线路。
  ///
  /// 全都试不通就回落到 GitHub 直连 —— 跟加这个功能之前一样，至少不会更差。
  static Future<String?> resolveDownload(UpdateInfo info) async {
    final origin = downloadUrlFor(info);
    if (origin == null) return null;
    final cached = _resolved[origin];
    if (cached != null) return cached;

    for (final url in downloadRoutes(info, origin)) {
      if (await _looksLikePackage(url)) {
        _resolved[origin] = url;
        return url;
      }
    }
    return origin;
  }

  /// 后台先把下载地址定下来（用户点「去下载」时就不用等了）。
  /// 启动自动检测和设置页里检查完之后都会调一次。
  static void prefetchDownload(UpdateInfo info) {
    unawaited(resolveDownload(info).catchError((_) => null));
  }

  /// 下载候选：先命中的那条线路 → 清单自带的 → 内置的 → GitHub 直连兜底。
  ///
  /// 公开是为了能被单测直接跑（这是"国内线路"这套的核心顺序，错一个位置用户就
  /// 会下到慢的或下不到）。
  static List<String> downloadRoutes(UpdateInfo info, String origin) {
    final seen = <String>{};
    return <String>[
      if (info.routePrefix != null) '${info.routePrefix}$origin',
      for (final m in info.mirrors) '$m$origin',
      for (final m in builtinMirrors) '$m$origin',
      origin,
    ].where(seen.add).toList();
  }

  /// 只读头 64KB，判断这是不是真安装包（ZIP 魔数 `PK\x03\x04`）。
  static Future<bool> _looksLikePackage(String url) async {
    try {
      final resp = await _dio(_probeTimeout).get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: const {'Range': 'bytes=0-65535'},
          // 206 = 服务器认了范围请求；[validateStatus] 里放行但不等于相信内容
          validateStatus: (c) => c != null && (c == 200 || c == 206),
        ),
      );
      final b = resp.data;
      return looksLikePackageBytes(b);
    } catch (_) {
      return false;
    }
  }

  /// 这段字节开头是不是 ZIP。APK 和 IPA 都是 zip，头四字节固定是 `PK\x03\x04`。
  ///
  /// 这是防**加速站返回错误页**的那道闸：那种响应状态码是 200、内容却是一段
  /// HTML，浏览器会把 HTML 存成 `xxx.apk`，用户装的时候才炸，而且完全看不出
  /// 问题在哪。公开是为了能被单测直接跑。
  static bool looksLikePackageBytes(List<int>? b) =>
      b != null &&
      b.length >= 4 &&
      b[0] == 0x50 &&
      b[1] == 0x4B &&
      b[2] == 0x03 &&
      b[3] == 0x04;

  /// 同一个版本只提醒一次。返回 true = 这是头一回，该发通知/弹窗了。
  ///
  /// 用户要的是"每次打开都**检测**一次"，检测确实每次都跑；但**每次都弹**同一个
  /// 版本就成了骚扰 —— 第二、三次启动还弹是没人受得了的。
  static Future<bool> announceOnce(String version) async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.getString(_kAnnounced) == version) return false;
      await sp.setString(_kAnnounced, version);
      return true;
    } catch (_) {
      // 存不下就照样提醒：宁可多提醒一次，也别永远不提醒
      return true;
    }
  }

  /// 加速线路 = 清单里带来的 + 内置那份（去重、保序）
  static Future<List<String>> _mirrors() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = sp.getStringList(_kMirrors) ?? const <String>[];
      final seen = <String>{};
      return <String>[
        for (final m in [...saved, ...builtinMirrors])
          if (m.isNotEmpty && seen.add(m)) m,
      ];
    } catch (_) {
      return builtinMirrors;
    }
  }

  static Future<void> _rememberMirrors(List<String> mirrors) async {
    if (mirrors.isEmpty) return;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_kMirrors, mirrors);
    } catch (_) {
      // 记不住就算了，下次用内置那份
    }
  }

  static List<String> _stringList(Object? v) => parseMirrors(v);

  /// 解析清单里的 `mirrors` 数组。公开是为了能被单测直接跑：
  /// 分发仓写错一个字符（比如塞了空串）不能让请求打到奇怪的地方去。
  static List<String> parseMirrors(Object? v) => v is List
      ? [
          for (final e in v)
            if (e.toString().trim().isNotEmpty) e.toString().trim(),
        ]
      : const [];

  /// 逐段比较 "2.1.0" 和 "2.10.3"。缺的段按 0 算。
  static int _compare(String a, String b) {
    final x = a.split('.');
    final y = b.split('.');
    for (var i = 0; i < 3; i++) {
      final xi = int.tryParse(i < x.length ? x[i] : '0') ?? 0;
      final yi = int.tryParse(i < y.length ? y[i] : '0') ?? 0;
      if (xi != yi) return xi > yi ? 1 : -1;
    }
    return 0;
  }
}