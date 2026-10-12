import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../services/schedule_prefs.dart';

/// 一套背景方案。
///
/// 要给出**两个底色**（浅色 / 深色）、**浅色的**六个调子色，以及**深色下色斑的强度**
/// （[darkBlobScale]）。深色模式的色斑用白色压在 [darkBase] 上（见 [_BackdropPainter]）
/// —— 深色底本来就黑，同一套调子色铺上去会脏，所以深色只有"白斑压黑底"这一种画法。
///
/// ⚠ [tones] **必须正好六个**，顺序对应 [_spots]。这条没法用 `assert` 兜底：下面这些
/// 实例是 `const` 的，而 `List.length` 不是常量表达式（实测直接报
/// `const_eval_property_access`，四个 error）。所以挪到
/// `test/backdrop_styles_test.dart` 里守。
class BackdropStyle {
  const BackdropStyle({
    required this.id,
    required this.label,
    required this.base,
    required this.darkBase,
    required this.tones,
    required this.darkBlobScale,
  });

  /// 存进 SharedPreferences 的值。**只能往后加，不能改已有的 id** ——
  /// 改了等于把用户已经选好的背景换掉。
  final int id;

  /// 设置里显示的名字
  final String label;

  /// 浅色模式的底色。必须**不透明**。
  final Color base;

  /// 深色模式的底色。必须**不透明**。
  ///
  /// 两套可以不一样：「冷岩」深色是偏冷的近黑（保留冷调），「默认」深色是**纯黑**。
  /// 原来深色下所有方案共用同一个近黑，于是切方案在深色里看不出任何变化 ——
  /// 用户明确提过这一档深色下应该是黑的。
  final Color darkBase;

  /// 六团色斑的调子色，顺序对应 [_spots]
  final List<Color> tones;

  /// 深色模式下六团白斑的不透明度折算系数（浅色那一套 opacity 的倍数）。
  ///
  /// **必须按方案给，不能所有方案共用一个数。** 原来这里是全局常量 0.40，深色下六团
  /// 永远是 `Colors.white` × 0.40，跟方案无关 —— 于是「默认」在深色里也糊上了和冷岩
  /// 一样厚的一层白斑，整片发灰、黑不下去。
  ///
  /// **允许为 0**：`0` 表示深色下就是 [darkBase] 那个纯色，一层色斑都不压
  /// （「默认」就是这一档：纯黑）。
  final double darkBlobScale;
}

/// 可选背景。**顺序就是设置里的显示顺序。**
///
/// 只留两套：「冷岩」是默认（略偏冷的浅灰，最中性、最不抢课表），「默认」几乎没有
/// 色斑 —— 浅色近白、深色纯黑，就是"什么都没有"那一档。原来还有「经典」（纯中性灰）
/// 和「暖灰」—— 精简掉了：四套的差别肉眼几乎分不出来，选择成本却是实实在在的。
///
/// ⚠ id 是**存进 SharedPreferences 的值，不能改**：
///
///  * **0** 以前是「经典」，现在是「冷岩」。老用户存的 0 会变成冷岩 —— 这正是要的
///    默认值，所以 0 必须继续是默认那一套。
///  * **1** 浅色一直是 `FAFAFA`，没变过。名字从「素白」改成「默认」，是因为它在深色
///    模式下是一张**黑**底，叫"素白"自相矛盾。**id 不动**：存着 1 的老用户看到的还是
///    同一套背景，只是名字换了。
///  * **2（暖灰）、3（冷岩）已退役**。老配置里存着 2/3 的会被 `backdropStyleOf`
///    退回第一套（冷岩）。别为了让它们"还能用"把新方案排到后面去。
const kBackdropStyles = <BackdropStyle>[
  BackdropStyle(
    id: 0,
    label: '冷岩',
    // 略偏冷的浅灰。这里 R<G<B 是**故意**的 —— 它是一套冷调背景，不是漏掉了色相。
    //
    // ⚠ 别把这条读成"背景不许有色相"。真正不许带色相的是**主题种子**
    // （见 `AppTheme.seed`）：种子偏一点，整套色板都跟着偏，底栏选中项会发蓝。
    // 背景只是底下的一层，偏冷是设计选择。
    base: Color(0xFFF4F6F8),
    // 深色：偏冷的近黑，R<G<B 的冷调照旧，跟浅色是同一套语汇
    darkBase: Color(0xFF0A0A0B),
    tones: [
      Color(0xFF93989F),
      Color(0xFFAEB3BA),
      Color(0xFF878C93),
      Color(0xFFA1A6AD),
      Color(0xFF8D929A),
      Color(0xFFA1A6AD),
    ],
    // 0.40 是原来那个全局值，冷岩在深色下的观感**保持原样**
    darkBlobScale: 0.40,
  ),
  BackdropStyle(
    id: 1,
    label: '默认',
    // **纯白**。这一档就是"什么都没有"：一张白纸 / 一张黑纸，不带任何色斑。
    base: Color(0xFFFFFFFF),
    // **纯黑**。和浅色的纯白是一对。
    darkBase: Color(0xFF000000),
    // 调子色也全给纯白：浅色下色斑和底色同色，等于不画。
    // （深色那边靠 `darkBlobScale: 0` 做到同一件事。）
    tones: [
      Color(0xFFFFFFFF),
      Color(0xFFFFFFFF),
      Color(0xFFFFFFFF),
      Color(0xFFFFFFFF),
      Color(0xFFFFFFFF),
      Color(0xFFFFFFFF),
    ],
    // **0**：深色下就是纯黑，一点色斑都不压。
    //
    // ⚠ 这里原来给 0.08，想的是"留一点结构给玻璃糊"。实测整片被抬到 0.06 亮度 ——
    // 那不是黑，是一层很淡的炭灰。用户要的是纯黑，玻璃能不能被看见不该由这一档负责
    // （要结构就选冷岩，或者用自定义照片）。
    darkBlobScale: 0,
  ),
];

/// 按 id 取方案。id 不认识就退回第一套（升级、改过配置也不至于白屏）。
BackdropStyle backdropStyleOf(int id) {
  for (final s in kBackdropStyles) {
    if (s.id == id) return s;
  }
  return kBackdropStyles.first;
}

/// 全 App 的底：一层色斑，或者用户自己选的一张照片。
///
/// **这是这一版最重要的认知修正。** 原来页面底色是一块纯色，而 `BackdropFilter`
/// 糊一块纯色，得到**还是那块纯色** —— 顶栏/底栏的玻璃无论怎么调模糊半径、描边、
/// 光泽，都"看不出来"。玻璃能不能被看见，取决于**背后有没有结构**，跟玻璃本身的
/// 参数基本无关。
///
/// 所以背景得先有东西。两条路：
///
///  * **色斑**（默认）：几团大而柔的调子，把背景压出真正的明暗范围（约 65~96）。
///    位置全按屏幕比例给，换机型、横竖屏都不会跑掉。
///  * **自定义照片**：从相册选一张，结构要多细有多细，玻璃的模糊一眼就能看出来。
///    这是把"玻璃像不像玻璃"真正交到用户手里的一条路 —— 色斑再怎么调都是柔的，
///    而一张照片天然带高频细节。
///
/// ⚠ **这里曾经加过一层程序生成的颗粒**，用来给玻璃提供高频细节（实测确实把模糊
/// 从"看不出来"变成 hf 1.10 → 0.48）。用户看到后判定影响观感，删掉了。所以现在
/// "细节"这件事只由照片提供；用色斑的时候玻璃能透出明暗，但糊不糊是看不出的，
/// 这是这套方案本身的边界，不是 bug。
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final prefs = SchedulePrefs.instance;
    // 换背景方案/换图/拖模糊滑块都要整层重画，三个 notifier 一起听。
    return AnimatedBuilder(
      animation: Listenable.merge([
        prefs.background,
        prefs.backgroundImage,
        prefs.backgroundBlur,
      ]),
      builder: (context, _) {
        final photo = prefs.backgroundImage.value;
        final style = backdropStyleOf(prefs.background.value);
        // 背景"本来的样子"。**照片只是盖在它上面的一层**，不是替代品。
        //
        // ⚠ 这里原来在照片那一路把底色垫成了 0xFF0A0A0B，于是有两个场景会整屏发黑：
        //  * **冷启动**：大图还没解码完，先黑一下才出现照片；
        //  * **文件已经没了**：系统清理、或者换机恢复备份只还原了配置没还原文件，
        //    那就一直黑着 —— 安卓上文件被清掉比 iOS 常见得多。
        // 垫上色斑之后，这两种情况露出来的都是应用本来就该有的背景。
        final base = ColoredBox(
          // 这层必须是**不透明**的：页面 Scaffold 都改成透明了，底要是也透明，
          // 露出来的就是窗口底色（安卓上是黑的）。深色下取方案自己的 darkBase ——
          // 每套方案在深色里也应该长得不一样（冷岩偏冷，默认纯黑）。
          color: dark ? style.darkBase : style.base,
          child: SizedBox.expand(
            child: CustomPaint(
              painter: _BackdropPainter(dark: dark, style: style),
            ),
          ),
        );
        if (photo == null) return base;
        return Stack(
          fit: StackFit.expand,
          children: [base, _photo(photo, prefs.backgroundBlur.value)],
        );
      },
    );
  }

  /// 自定义背景照片。
  ///
  /// **模糊是做在图上的，不是做在玻璃上。** 玻璃本来就带 `BackdropFilter`，这里这层
  /// 管的是另一件事：壁纸本身要不要糊。两个混在一起会让人分不清哪个滑块在起作用。
  ///
  /// ⚠ 模糊会让图像**边缘**透出底色。`ImageFilter` 在边界采样越界，半径 30 就相当于
  /// 约 30 逻辑像素的一圈向外渐隐。所以套一层 `ClipRect` + 把图放大 12%——把那圈渐隐
  /// 推到可视区之外。不放大就会在四边看到一圈脏边。
  Widget _photo(String path, double blur) {
    Widget img = Image.file(
      File(path),
      fit: BoxFit.cover,
      // 解码失败（文件被系统清掉、换机恢复备份）时不要整屏抛错，也不要留一块黑：
      // 返回空盒子，透出下面那层色斑背景。顺便把这条已经失效的记录抹掉。
      errorBuilder: (_, __, ___) {
        _forgetBrokenPhoto(path);
        return const SizedBox.shrink();
      },
    );
    final active = blur > 0.5;
    if (active) {
      img = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: img,
      );
    }
    return ClipRect(
      child: Transform.scale(
        scale: active ? 1.12 : 1.0,
        child: SizedBox.expand(child: img),
      ),
    );
  }

  /// 照片文件已经不在了（被系统清理、换机只还原了配置没还原文件）。
  ///
  /// 一直重试一个不存在的路径没有意义：把记录抹掉，设置页里就会如实显示"当前没有
  /// 自定义背景"，下次用户再选一张即可。用集合去重是因为这个回调在 build 里跑，
  /// 不去重就会**每帧写一次盘**。
  static final Set<String> _forgottenPhotos = <String>{};

  static void _forgetBrokenPhoto(String path) {
    if (!_forgottenPhotos.add(path)) return;
    SchedulePrefs.instance.setBgImage(null);
  }
}

/// 屏幕底部那层「由浅入白」的遮罩。
///
/// 底栏是**悬浮**的（`extendBody: true`，页面内容从它底下穿过去）。没有这一层时，
/// 课表滚到底部是被硬切一刀 —— 课程格子会在胶囊上方戛然而止。加一层从透明渐变到
/// 背景色的遮罩之后，内容滚过去是**淡进背景里**，胶囊也就有了一个底。
///
/// 注意这**不是阴影**：阴影是往下投的暗色，方向朝外；这一层是往上化开的背景色，
/// 方向朝内，为的是把"内容还在继续"这件事收干净。
///
/// ⚠ 三处容易做错：
///
///  * **渐变末端必须和背景同色。** 最下面是完全不透明的，颜色差一点点就会在屏幕
///    底边露出一条接缝。所以这里**不取** `colorScheme.surface` —— 那是 M3 从种子
///    推导出来的另一套中性色，跟 [GlassBackdrop] 真正铺的那层对不上；直接取背景用
///    的那个 `base`。
///  * **高度要和底栏槽位一致。** 页面拿到的 `MediaQuery.padding.bottom` 就是槽位
///    高度；遮罩比它高，就会盖住本该露出来的正文。
///  * **`IgnorePointer`。** 它横跨整宽压在内容上，绝不能吃掉点击。
class BottomFade extends StatelessWidget {
  const BottomFade({super.key, required this.height});

  /// 要和底栏槽位高度一致（胶囊高 + 底部边距），由调用方算好传进来
  final double height;

  /// 渐变分档。
  ///
  /// **不是两点直线。** 直线从第一个像素就开始变白，屏幕中下部会被整片洗淡。这里
  /// 让上面约 35% 基本保持透明，之后才明显加深 —— "从下往上慢慢化开"。
  static const _stops = <double>[0.0, 0.35, 0.68, 1.0];
  static const _alphas = <double>[0.0, 0.12, 0.46, 1.0];

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final prefs = SchedulePrefs.instance;
    return IgnorePointer(
      child: SizedBox(
        height: height,
        child: AnimatedBuilder(
          // 换背景方案 / 换照片都要跟着改颜色，否则遮罩末端会跟背景差一点
          animation: Listenable.merge([prefs.background, prefs.backgroundImage]),
          builder: (context, _) {
            final hasPhoto = prefs.backgroundImage.value != null;
            final style = backdropStyleOf(prefs.background.value);
            // 渐变末端必须和**背景那一层**完全同色：最下面是全不透明的，差一点点
            // 就会在屏幕底边露出一条接缝。所以这里取的是背景方案自己那个底色
            // （浅色 base / 深色 darkBase），**不是** colorScheme 里那套。
            //
            // 有照片时没有"单一底色"可取，退回纯白 / 近黑 —— 照片上的白色渐隐本来
            // 也是最常见的那种做法。
            final base = hasPhoto
                ? (dark ? const Color(0xFF0A0A0B) : Colors.white)
                : (dark ? style.darkBase : style.base);
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [for (final a in _alphas) base.withOpacity(a)],
                  stops: _stops,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 六团色斑：(fx, fy, fr, opacity)。
///
/// 位置和半径都是**量出来的**，别凭感觉改：
///
///  1. **化开带必须从顶栏、底栏底下穿过去。** 不能把玻璃压在色斑平坦的中心上 ——
///     那样玻璃背后是一片纯色，模糊前后一模一样。上一版就正好把玻璃放在了最没有
///     结构的地方（色斑中心 fy 0.06 / 0.14 落在顶栏上）。现在第 3、4 团的上缘切
///     顶栏（y 0~200），第 5、6 团的下缘切底栏（y 2215~2400）。
///  2. **半径不能用大。** 半径 0.9 的色斑宽度已接近整块屏，横向完全没有起伏 ——
///     实测剖面上每行的横向差只有 0.0~0.6 个亮度点，等于没有结构。给玻璃当"糊料"
///     的必须是小而明确的东西，所以第 3~6 团的半径压在 0.40~0.46。
///  3. **背景和玻璃不能一样亮。** 曾经背景在 71~96、玻璃约 93，几乎同亮度，玻璃
///     才"根本看不出来"。调子色的不透明度给到 0.40~0.50，把背景压出真正的范围。
///
/// 这里**没有红色**：红只留给"正在上课"和"今天"。上一版在背景里放过一团 12% 的
/// 红，实测偏红像素占了全屏 12.3%，那是一大片粉，不是"黑白 + 一点淡红强调"。
const _spots = <(double, double, double, double)>[
  (0.50, 0.30, 1.05, 0.30), // 大调子：定整体明暗走向
  (0.25, 0.90, 0.85, 0.24), // 大调子
  (0.24, 0.22, 0.46, 0.50), // 上缘切顶栏
  (0.70, 0.20, 0.40, 0.44), // 上缘切顶栏
  (0.38, 0.78, 0.46, 0.46), // 下缘切底栏
  (0.82, 0.78, 0.42, 0.40), // 下缘切底栏
];

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter({required this.dark, required this.style});

  final bool dark;
  final BackdropStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    // 强度为 0 就整层不画（「默认」在深色下就是纯黑，不该压任何色斑）。
    // 画一层全透明的圆没有意义，还得为它建 shader。
    if (dark && style.darkBlobScale <= 0) return;
    for (var i = 0; i < _spots.length; i++) {
      final (fx, fy, fr, opacity) = _spots[i];
      // 深色模式一律白色压黑底；浅色用方案给的调子色。
      // **强度按方案给**（`style.darkBlobScale`）：共用一个数的话，浅色下"几乎没有
      // 色斑"的「默认」在深色里会糊上跟冷岩一样厚的一层白，整片发灰、黑不下去。
      final tone = dark ? Colors.white : style.tones[i];
      final color = tone.withOpacity(dark ? opacity * style.darkBlobScale : opacity);
      final center = Offset(size.width * fx, size.height * fy);
      final radius = size.shortestSide * fr;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            // 三个 color、三个 stop：前两个同色，把色斑实体撑到 86%，最后 14% 才
            // 化开（stops 长度必须跟 colors 对上）。
            //
            // ⚠ 这个 14% 是调过的：原来给 30%，化开带约 260px，比模糊半径
            // （30 逻辑 ≈ 77 物理像素）宽得多 —— 糊一条本来就极缓的过渡，眼睛
            // 看不出差别。现在化开带约 110px，跟模糊半径同量级。
            colors: [color, color, color.withOpacity(0)],
            stops: const [0.0, 0.86, 1.0],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BackdropPainter old) =>
      old.dark != dark || old.style.id != style.id || old.style.darkBlobScale != style.darkBlobScale;
}