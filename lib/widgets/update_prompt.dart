import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_info.dart';
import '../services/update_service.dart';
import 'glass_dialog.dart';

/// 「发现新版本」的 App 内弹窗。
///
/// 抽出来是因为现在**两个地方**都要用：设置页里手动点「检查更新」，以及启动时
/// 自动检测到新版本（见 `home_shell.dart`）。各写一份的话，改文案就得改两处。
Future<void> showUpdatePrompt(BuildContext context, UpdateInfo info) async {
  await showGlassDialog<void>(
    context: context,
    title: Text('发现新版本 ${info.version}'),
    content: Text(info.notes.isEmpty
        ? '当前 ${AppInfo.version}，可以更新到 ${info.version}。'
        : info.notes),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('以后再说'),
      ),
      FilledButton(
        onPressed: () async {
          // 解析实际下载地址要 await（挑线路 + 确认拿到的是安装包），
          // 这里先把要用的东西抓在手里，await 之后就不再碰 context
          final nav = Navigator.of(context);
          final messenger = ScaffoldMessenger.of(context);
          final url = await UpdateService.resolveDownload(info);
          nav.pop();
          if (url != null) await openDownloadUrl(messenger, url);
        },
        child: const Text('去下载'),
      ),
    ],
  );
}

/// 把下载地址丢给系统浏览器。
///
/// 不在 App 里下载安装：Android 要申请「安装未知应用」权限，iOS 的未签名 IPA 又
/// 必须走 TrollStore。两条路都丢给系统浏览器最省事，也最不容易出错。
///
/// 不用 `canLaunchUrl`：它在 Android 11+ 要在 manifest 里声明 `<queries>`，
/// 直接 launch、失败就 catch，能省掉一处平台配置。
Future<void> openDownloadUrl(ScaffoldMessengerState messenger, String url) async {
  try {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) _report(messenger, url);
  } catch (_) {
    _report(messenger, url);
  }
}

void _report(ScaffoldMessengerState messenger, String url) {
  messenger.showSnackBar(SnackBar(content: Text('打不开浏览器，请手动访问：$url')));
}