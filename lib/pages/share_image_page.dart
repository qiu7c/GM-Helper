import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

import '../models/course.dart';
import '../services/schedule_prefs.dart';
import '../widgets/app_theme.dart';
import '../widgets/timetable_grid.dart';

/// 把这一周的课表画成一张图分享出去。
///
/// 不是截屏：整块内容在一个**固定宽度**的画布里重新排一遍（[_canvasWidth]），
/// 再按 3 倍像素密度导出，所以在小屏手机上生出来的图一样清楚。
/// 画布固定用浅色主题（见 [AppTheme]），深色模式下也不受影响。
class ShareImagePage extends StatefulWidget {
  /// 这一周要显示的课（调用方已经按周过滤过）
  final List<Course> courses;
  final int week;
  final String? campusId;

  const ShareImagePage({
    super.key,
    required this.courses,
    required this.week,
    this.campusId,
  });

  @override
  State<ShareImagePage> createState() => _ShareImagePageState();
}

class _ShareImagePageState extends State<ShareImagePage> {
  final GlobalKey _boundary = GlobalKey();
  bool _busy = false;

  /// 画布宽度。写死，不跟屏幕走 —— 否则小屏导出的图窄得没法看。
  static const double _canvasWidth = 420;

  /// 导出倍数：420 宽 → 1260 像素
  static const double _pixelRatio = 3;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final monday = SchedulePrefs.instance.mondayOfWeek(widget.week);
    final sunday = monday.add(const Duration(days: 6));

    return Scaffold(
      appBar: AppBar(
        title: const Text('导出课表图片'),
        actions: [
          TextButton.icon(
            onPressed: _busy ? null : _share,
            icon: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share, size: 18),
            label: const Text('分享'),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                // 预览整体缩到屏幕里，但 RepaintBoundary 在缩放**里面**：
                // toImage 用的是它自己的尺寸，跟外面缩了多少无关。
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: RepaintBoundary(
                    key: _boundary,
                    child: SizedBox(
                      width: _canvasWidth,
                      // 分享出去的图固定浅色：深色 scheme 的前景色是浅的，
                      // 压在白底上会看不见。
                      child: Theme(
                        data: AppTheme.light(),
                        child: Material(
                          color: Colors.white,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  '第 ${widget.week} 周',
                                  style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${monday.month}月${monday.day}日 - '
                                  '${sunday.month}月${sunday.day}日',
                                  style: const TextStyle(
                                      fontSize: 12, color: Colors.grey),
                                ),
                                const SizedBox(height: 12),
                                TimetableGrid(
                                  courses: widget.courses,
                                  week: widget.week,
                                  campusId: widget.campusId,
                                  embedded: true,
                                  // 图片里点了没反应，但格子内部是 InkWell，
                                  // 得给它一对回调
                                  onTap: (_) {},
                                  onLongPress: (_) {},
                                ),
                                const Divider(height: 20),
                                const Text(
                                  '由 GMPluse 导出',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 10, color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '分享出去的只有课表图片，不含账号信息。',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final obj = _boundary.currentContext?.findRenderObject();
      if (obj is! RenderRepaintBoundary) return;

      final image = await obj.toImage(pixelRatio: _pixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) {
        _toast('生成图片失败');
        return;
      }

      // 用 XFile.fromData 直接给字节，省掉 path_provider 那套临时文件；
      // 文件名用 ASCII，中文名在某些系统上会乱码。
      final file = XFile.fromData(
        data.buffer.asUint8List(),
        mimeType: 'image/png',
        name: 'GMPluse-Week${widget.week}.png',
      );

      final box = context.findRenderObject();
      await Share.shareXFiles(
        [file],
        subject: 'GMPluse 第 ${widget.week} 周课表',
        // iPad 上分享面板是 popover，不给锚点会直接崩
        sharePositionOrigin:
            box is RenderBox ? box.localToGlobal(Offset.zero) & box.size : null,
      );
    } catch (e) {
      _toast('分享失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }
}
