import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gdgm_schedule/services/app_info.dart';
import 'package:gdgm_schedule/services/update_service.dart';

/// 更新这套里最容易写错、也最难在界面上看出来的三件事：
///
///   1. **线路顺序** —— 排错了用户就会下到慢的，甚至下不到；
///   2. **拿到的是不是真安装包** —— 加速站挂掉时返回 200 + HTML，浏览器会把
///      HTML 存成 xxx.apk，装的时候才炸。这个坑必须在请求层就挡住；
///   3. **清单里的 mirrors 解析** —— 分发仓改线路不用发新版，写错一个字符
///      不能把请求打到奇怪的地方去。
void main() {
  const origin =
      'https://github.com/qiu7c/GMPluse-Release/releases/latest/download/GMPluse-v2.2.5.apk';

  group('下载线路顺序', () {
    test('命中的线路排第一，然后清单自带的、内置的，GitHub 直连永远兜底', () {
      const info = UpdateInfo(
        version: '2.2.5',
        routePrefix: 'https://hit.example/',
        mirrors: ['https://from-manifest.example/'],
      );
      final routes = UpdateService.downloadRoutes(info, origin);
      expect(routes.first, 'https://hit.example/$origin');
      expect(routes[1], 'https://from-manifest.example/$origin');
      expect(routes.last, origin, reason: '全都试不通时还得回到直连，至少不比以前差');
      for (final m in UpdateService.builtinMirrors) {
        expect(routes, contains('$m$origin'));
      }
    });

    test('重复前缀只留一份（清单里塞了跟内置一样的那条）', () {
      final dup = UpdateService.builtinMirrors.first;
      const info = UpdateInfo(version: '2.2.5');
      final withDup = UpdateInfo(version: '2.2.5', mirrors: [dup, dup]);
      expect(
        UpdateService.downloadRoutes(withDup, origin)
            .where((u) => u == '$dup$origin')
            .length,
        1,
      );
      // 没有重复时条数 = 内置 + 直连
      expect(UpdateService.downloadRoutes(info, origin).length,
          UpdateService.builtinMirrors.length + 1);
    });

    test('清单没带线路、也没命中线路时：少几条而已，直连不丢', () {
      const info = UpdateInfo(version: '2.2.5');
      final routes = UpdateService.downloadRoutes(info, origin);
      expect(routes.last, origin);
      expect(routes.any((u) => u.contains('hit.example')), isFalse);
    });
  });

  group('ZIP 魔数（防把代理的错误页当安装包下载）', () {
    test('PK\x03\x04 开头算安装包', () {
      expect(
        UpdateService.looksLikePackageBytes([0x50, 0x4B, 0x03, 0x04, 0, 0]),
        isTrue,
      );
    });

    test('HTML 错误页不算', () {
      expect(
        UpdateService.looksLikePackageBytes(
            utf8.encode('<!DOCTYPE html><html><body>404</body></html>')),
        isFalse,
      );
    });

    test('空 body / 太短的不算', () {
      expect(UpdateService.looksLikePackageBytes(null), isFalse);
      expect(UpdateService.looksLikePackageBytes(const []), isFalse);
      expect(UpdateService.looksLikePackageBytes(const [0x50, 0x4B]), isFalse);
    });
  });

  group('清单里的 mirrors 解析', () {
    test('正常数组原样取出', () {
      expect(
        UpdateService.parseMirrors(['https://a/', 'https://b/']),
        ['https://a/', 'https://b/'],
      );
    });

    test('空串和空白项丢掉', () {
      expect(
        UpdateService.parseMirrors(['https://a/', '', '   ']),
        ['https://a/'],
      );
    });

    test('不是数组就给空（老清单没有这个字段）', () {
      expect(UpdateService.parseMirrors(null), isEmpty);
      expect(UpdateService.parseMirrors('https://a/'), isEmpty);
    });
  });

  group('版本比较', () {
    test('优先比 versionCode', () {
      AppInfo.version = '2.2.4';
      AppInfo.buildNumber = '16';
      expect(
        UpdateService.isNewer(const UpdateInfo(version: '2.0.0', versionCode: 17)),
        isTrue,
      );
      expect(
        UpdateService.isNewer(const UpdateInfo(version: '9.9.9', versionCode: 16)),
        isFalse,
        reason: '文案写错不该盖过单调递增的 build number',
      );
    });

    test('拿不到 versionCode 时退回比版本字符串', () {
      AppInfo.version = '2.2.4';
      AppInfo.buildNumber = '16';
      expect(UpdateService.isNewer(const UpdateInfo(version: '2.2.5')), isTrue);
      expect(UpdateService.isNewer(const UpdateInfo(version: '2.2.4')), isFalse);
      expect(UpdateService.isNewer(const UpdateInfo(version: '2.10.0')), isTrue,
          reason: '按段比，不能按字符串比（"2.10" < "2.9"）');
    });
  });
}