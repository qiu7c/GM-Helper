import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../config.dart';
import 'app_info.dart';

/// 一个新版本的信息，来自分发仓里的 latest.json
class UpdateInfo {
  final String version;
  final int? versionCode;
  final String apkUrl;
  final String ipaUrl;
  final String notes;

  const UpdateInfo({
    required this.version,
    this.versionCode,
    this.apkUrl = '',
    this.ipaUrl = '',
    this.notes = '',
  });
}

/// 更新检查。
///
/// 读的是**公开分发仓**里的 latest.json —— 源码仓是私有的，App 永远不碰它，
/// 所以这个请求不带任何凭证（往 App 里塞 token 比公开源码还糟）。
///
/// 一切失败都当成"没有更新"：网络不通、分发仓还没建、json 坏了、GitHub 抽风，
/// 一律静默返回 null，绝不能因为检查更新失败就打扰用户。
class UpdateService {
  UpdateService._();

  static Future<UpdateInfo?> check() async {
    if (AppConfig.updateManifestUrl.isEmpty) return null;
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        // releases/latest/download/... 是 302 跳到 objects.githubusercontent.com，
        // 必须跟着走，否则拿到的是个空的重定向响应
        followRedirects: true,
        maxRedirects: 5,
      ));
      final resp = await dio.get<String>(
        AppConfig.updateManifestUrl,
        options: Options(responseType: ResponseType.plain),
      );
      final raw = resp.data;
      if (raw == null || raw.trim().isEmpty) return null;

      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final info = UpdateInfo(
        version: (map['version'] ?? '').toString(),
        versionCode: int.tryParse((map['versionCode'] ?? '').toString()),
        apkUrl: (map['apk'] ?? '').toString(),
        ipaUrl: (map['ipa'] ?? '').toString(),
        notes: (map['notes'] ?? '').toString(),
      );
      if (info.version.isEmpty) return null;
      return isNewer(info) ? info : null;
    } catch (_) {
      return null;
    }
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

  /// 当前平台该下哪个包。iOS 是未签名 IPA，下载后用 TrollStore 侧载。
  static String? downloadUrlFor(UpdateInfo info) {
    if (Platform.isIOS) return info.ipaUrl.isEmpty ? null : info.ipaUrl;
    if (Platform.isAndroid) return info.apkUrl.isEmpty ? null : info.apkUrl;
    return null;
  }

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
