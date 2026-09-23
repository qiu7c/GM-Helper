import 'package:flutter/material.dart';

/// 课表加载时的骨架屏：按真实几何摆一批灰块。
///
/// 换掉的原来是屏幕正中一个孤零零的 `CircularProgressIndicator` —— 那是"默认
/// Flutter"最典型的一帧。**不做扫光（shimmer）**：那要多一个
/// `AnimationController` 和一层 `ShaderMask`，而这块只在冷启动出现一瞬，摆对
/// 形状就够了。
///
/// 几何跟 `TimetableGrid` 对齐（38 的时间列、7 个等宽日列、52 高的表头、每行
/// 最低 92），真数据接上来的时候画面不会整体跳一下。
class TimetableSkeleton extends StatelessWidget {
  const TimetableSkeleton({super.key});

  static const double _timeCol = 38;
  static const double _headerH = 52;
  static const double _rowMinH = 92;

  /// 高度量不出来时（外面是不限高的容器）退回这个行数
  static const int _rows = 5;
  /// 内容再高也不会超过这个行数（真实课表最多也就十几节）
  static const int _maxRows = 12;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 用 onSurface 的低透明度而不是写死的灰：深浅两套配色下都对
    final strong = scheme.onSurface.withOpacity(0.07);
    final faint = scheme.onSurface.withOpacity(0.04);

    return Semantics(
      label: '正在加载课表',
      child: LayoutBuilder(builder: (context, c) {
        final dayW = (c.maxWidth - _timeCol) / 7;

        // 按可用高度决定画几行：短屏少画点，高屏别在底下留一大块空白。
        // 高度可能是无限的（外面若是滚动视图），那时退回固定行数。
        final fit = c.maxHeight.isFinite
            ? ((c.maxHeight - _headerH) / _rowMinH).floor()
            : _rows;
        final rows = fit < 1 ? 1 : (fit > _maxRows ? _maxRows : fit);

        Widget bar(double w, double h, Color color, double radius) => Container(
              width: w,
              height: h,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(radius),
              ),
            );

        // 内容比屏幕高时安静地裁掉，不要抛 overflow。用
        // NeverScrollableScrollPhysics 而不是 ClipRect：滚动视图能连底部那块
        // 溢出报告一起处理掉。
        return SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const SizedBox(width: _timeCol, height: _headerH),
                  for (var d = 0; d < 7; d++)
                    SizedBox(
                      width: dayW,
                      height: _headerH,
                      child: Center(child: bar(dayW * 0.5, 14, strong, 7)),
                    ),
                ],
              ),
              for (var r = 0; r < rows; r++)
                SizedBox(
                  height: _rowMinH,
                  child: Row(
                    // stretch 让每格拿到确定的高度，DecoratedBox 才能撑满
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: _timeCol,
                        child: Center(child: bar(16, 10, strong, 5)),
                      ),
                      for (var d = 0; d < 7; d++)
                        SizedBox(
                          width: dayW,
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: faint,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }
}
