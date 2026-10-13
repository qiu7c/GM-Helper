import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_info.dart';
import 'update_service.dart';

/// 「发现新版本」的那条系统通知。
///
/// 单独一个类，不塞进 [UpdateService]：那边是**纯逻辑**（怎么取清单、怎么比版本、
/// 怎么挑线路），这里依赖平台插件。分开之后逻辑那部分还能被单元测试直接跑。
class UpdateNotifier {
  UpdateNotifier._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  /// 安卓 8+ 的通知必须挂在通道上，第一次 show 时系统会自动建。
  static const String _channelId = 'gmpluse_update';
  static const String _channelName = '版本更新';

  /// 固定通知 id：同一个版本反复提醒只会**覆盖**那一条，不会堆一屏。
  static const int _id = 1001;

  static Future<void> _init() async {
    if (_inited) return;
    await _plugin.initialize(const InitializationSettings(
      // 小图标用 App 自己的 launcher 图标（系统会取它的单色剪影）
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      // ⚠ 这里**不**申请权限。开屏就问"允许通知吗"是最招人烦的那种，
      // 真检测到新版本时再问（见 [show]）。
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    ));
    _inited = true;
  }

  /// 有更新时提醒一次。
  ///
  /// 用户拒绝了通知权限就静默跳过 —— App 内的弹窗仍然会出，不至于因为拒了通知
  /// 就完全不知道有新版本。
  static Future<void> show(UpdateInfo info) async {
    try {
      await _init();

      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        // 安卓 13+ 的运行时权限，返回 null 表示这个系统版本不需要问
        final ok = await android.requestNotificationsPermission();
        if (ok == false) return;
      }
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) {
        final ok = await ios.requestPermissions(
            alert: true, badge: true, sound: true);
        if (ok == false) return;
      }

      await _plugin.show(
        _id,
        '发现新版本 ${info.version}',
        '当前 ${AppInfo.version}，打开 App 就能看到更新说明。',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: '有新版本可以更新时提醒',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {
      // 通知只是锦上添花：任何失败都不该影响启动，也不该影响 App 内的弹窗
    }
  }
}