import 'package:package_info_plus/package_info_plus.dart';

/// App 自身的版本信息。
///
/// 版本号唯一的来源是 `pubspec.yaml` 里的 `version: 2.1.0+11`，运行期读出来。
/// 以前关于页写死了一个 `static const version`，跟 pubspec 是两处，改版本时
/// 忘一个就会出现「关于页写的和实际装上的不是同一个版本」。
///
/// 在 `main()` 里 `await AppInfo.load()`，之后全局同步可用。
class AppInfo {
  AppInfo._();

  /// 形如 "2.1.0"
  static String version = '';

  /// 形如 "11"（pubspec 里 `+` 后面那截）
  static String buildNumber = '';

  /// 关于页展示用，形如 "2.1.0+11"
  static String get full =>
      buildNumber.isEmpty ? version : '$version+$buildNumber';

  static Future<void> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      version = info.version;
      buildNumber = info.buildNumber;
    } catch (_) {
      // 拿不到就留空，界面上显示 "-"。绝不因为读版本号失败影响启动。
      if (version.isEmpty) version = '-';
    }
  }
}
