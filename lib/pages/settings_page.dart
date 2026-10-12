import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/course.dart';
import '../services/app_info.dart';
import '../services/auth_store.dart';
import '../services/schedule_prefs.dart';
import '../services/schedule_service.dart';
import '../services/update_service.dart';
import '../widgets/glass_backdrop.dart';
import '../widgets/glass_dialog.dart';
import 'about_page.dart';

/// 设置页：从「我的」收纳过来的全部可改项。
///
/// **为什么单开一页。** 「我的」原本把两类东西混在同一条流里：**学籍信息**（"关于我
/// 这个人的数据"）和**一堆开关**（"我要改 App 的行为"）。学籍可能有十几行，开关全被
/// 淹在后面 —— 每次换个背景、换学期，都得从一整屏个人信息里划过去。分开之后「我的」
/// 只剩身份和学籍，这里放全部可改项。
///
/// 退出登录也放这一页：它属于"改状态"，不属于"我是谁"。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<SelectOption> _terms = [];
  List<SelectOption> _campuses = [];
  String? _term;
  String? _campus;

  /// 查到的可用新版本。null 表示"已是最新 / 还没查 / 查失败"，三种都不打扰用户。
  UpdateInfo? _update;
  bool _checkingUpdate = false;

  /// 这页**不判定登录态**，只是借"能不能拉到学期/校区"来决定那两条可点不可点。
  /// 会话到底有没有效由课表页和「我的」页去判 —— 它们在同一棵树上，重复判定只会
  /// 互相打架（见 `AuthStore.clearSession` 里那段比对逻辑）。
  bool _canPick = false;

  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _loadOptions();
    _checkUpdate();
  }

  Future<void> _loadOptions() async {
    final seq = ++_seq;
    final cookie = await AuthStore.getCookie();
    if (!mounted || seq != _seq) return;
    if (cookie == null || cookie.isEmpty) {
      setState(() => _canPick = false);
      return;
    }
    try {
      final r = await ScheduleService(cookie).fetch(
        term: await AuthStore.getLastTerm(),
        campus: await AuthStore.getLastCampus(),
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _canPick = true;
        _terms = r.terms;
        _campuses = r.campuses;
        _term = r.selectedTerm;
        _campus = r.selectedCampus;
      });
      SchedulePrefs.instance.sync(term: _term, campus: _campus);
    } catch (_) {
      if (!mounted || seq != _seq) return;
      // 拉不到（离线 / 会话已过期）不算致命：那两条变灰、其余照常能用。
      //
      // ⚠ 这里**故意不清 cookie**。清会话是课表页和「我的」页的职责，设置页跟着
      // 清会把那边正在跑的自动重登打断 —— 用户看到的就是"自动登录刚成功又被踢出去"。
      setState(() => _canPick = false);
    }
  }

  // ---------- 外观 ----------

  Widget _themeTile() {
    final mode = SchedulePrefs.instance.theme;
    return ListTile(
      leading: const Icon(Icons.brightness_6_outlined),
      title: const Text('深浅色'),
      subtitle: Text(_themeLabel(mode)),
      trailing: const Icon(Icons.chevron_right),
      onTap: _pickTheme,
    );
  }

  String _themeLabel(ThemeMode m) {
    switch (m) {
      case ThemeMode.system:
        return '跟随系统';
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
    }
  }

  Future<void> _pickTheme() async {
    final cur = SchedulePrefs.instance.theme;
    final picked = await showGlassSheet<ThemeMode>(
      context: context,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetTitle('深浅色'),
          for (final m in ThemeMode.values)
            ListTile(
              title: Text(_themeLabel(m)),
              trailing: m == cur ? const Icon(Icons.check) : null,
              selected: m == cur,
              onTap: () => Navigator.pop(context, m),
            ),
        ],
      ),
    );
    if (picked == null || picked == cur) return;
    await SchedulePrefs.instance.setThemeMode(picked);
    if (mounted) setState(() {});
  }

  /// 「背景」—— 换整套底色，连同玻璃背后那层结构一起换。
  ///
  /// 这不是纯装饰：顶栏和底栏都是玻璃，而玻璃能不能被看出来**完全取决于背后有
  /// 没有结构**（见 `glass_backdrop.dart` 的类注释）。所以换背景等于换玻璃的观感，
  /// 是整个外观里少数几个真正管用的开关之一。
  Widget _backgroundTile() {
    final prefs = SchedulePrefs.instance;
    // 有照片时以照片为准 —— 它压在内置方案上面
    final label =
        prefs.bgImage != null ? '自定义照片' : backdropStyleOf(prefs.bgStyle).label;
    return ListTile(
      leading: const Icon(Icons.wallpaper_outlined),
      title: const Text('背景'),
      subtitle: Text(label),
      trailing: const Icon(Icons.chevron_right),
      onTap: _pickBackground,
    );
  }

  /// 背景图模糊半径的上限。
  ///
  /// 40 已经接近"糊成一片色块"了（屏幕宽 420 逻辑，40 的半径够抹掉大部分结构）。
  /// 再往上调对背景没有意义 —— 真想更糊，不如直接选一套内置方案。
  static const double _bgBlurMax = 40;

  Future<void> _pickBackground() async {
    // 这个表要**一直开着**：换方案和拖模糊都是即时生效的（背景在 MaterialApp.builder
    // 上，notifier 一变整层就重画），所以要一边调一边看。因此不用"选一项就 pop 回一个
    // 值"的写法，改成表里直接写 prefs + StatefulBuilder 局部刷新。
    await showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final theme = Theme.of(ctx);
          final prefs = SchedulePrefs.instance;
          final photo = prefs.bgImage;
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _sheetTitle('背景'),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('从相册选择'),
                  subtitle: const Text('选一张图片作为页面背景'),
                  trailing: photo == null ? null : const Icon(Icons.check),
                  onTap: () async {
                    await _pickPhoto();
                    setSheet(() {});
                  },
                ),
                if (photo != null) ...[
                  ListTile(
                    leading: const Icon(Icons.hide_image_outlined),
                    title: const Text('不用照片'),
                    onTap: () async {
                      await prefs.setBgImage(null);
                      setSheet(() {});
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 12, 0),
                    child: Row(
                      children: [
                        const Icon(Icons.blur_on, size: 20),
                        const SizedBox(width: 10),
                        const Text('模糊'),
                        Expanded(
                          child: Slider(
                            value:
                                prefs.bgBlur.clamp(0.0, _bgBlurMax).toDouble(),
                            max: _bgBlurMax,
                            divisions: (_bgBlurMax / 4).round(),
                            label: '${prefs.bgBlur.round()}',
                            onChanged: (v) {
                              // 不 await：拖滑块每帧都会调，等写盘会卡手
                              prefs.setBgBlur(v);
                              setSheet(() {});
                            },
                          ),
                        ),
                        SizedBox(
                          width: 28,
                          child: Text(
                            '${prefs.bgBlur.round()}',
                            textAlign: TextAlign.right,
                            style: theme.textTheme.labelMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                for (final s in kBackdropStyles)
                  ListTile(
                    leading: _bgSwatch(s),
                    title: Text(s.label),
                    trailing: (photo == null && s.id == prefs.bgStyle)
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () async {
                      // 选了内置方案就把照片撤掉：照片是压在所有方案上面的，
                      // 留着它会让"选了却没变"。
                      if (photo != null) await prefs.setBgImage(null);
                      await prefs.setBgStyle(s.id);
                      setSheet(() {});
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  /// 从相册选一张照片当背景。
  ///
  /// 要**拷贝一份**到 App 私有目录：`image_picker` 给的是相册里那条临时路径，
  /// 重启或被系统清理之后就失效了。真正存下来的是我们自己那份。
  ///
  /// 顺便把长边压到 2000：背景只需要屏幕那么大（1080 宽），拿一张 12MP 原图去解码
  /// 纯粹是浪费显存和启动时间。
  Future<void> _pickPhoto() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2000,
        maxHeight: 2000,
      );
      if (picked == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final dot = picked.path.lastIndexOf('.');
      final ext = dot >= 0 ? picked.path.substring(dot) : '.jpg';
      // ⚠ **文件名每次都必须不一样。**
      //
      // 原来固定叫 `bg_image$ext`，于是第二次选图写到的是**同一个路径**，两个坑
      // 同时踩中：
      //   1. `SchedulePrefs.setBgImage` 开头是 `if (path == 当前值) return` —— 路径
      //      没变，notifier 压根不通知，界面不重建；
      //   2. 就算重建了，`Image.file` 是拿**路径**当图片缓存键的，同一个路径永远
      //      取回第一次解码的那张。
      // 结果就是"从相册选一张之后再也换不成别的"（用户实测反馈）。加上时间戳，
      // 两个问题一起消失。
      final dest =
          File('${dir.path}/bg_image_${DateTime.now().millisecondsSinceEpoch}$ext');
      final old = SchedulePrefs.instance.bgImage;
      await File(picked.path).copy(dest.path);
      await SchedulePrefs.instance.setBgImage(dest.path);
      // 把上一张（我们自己拷进私有目录的那份）清掉：文件删掉，顺手从图片缓存里
      // 踢出去，免得内存里还压着一张 2000px 的位图。删不掉也不影响换图。
      if (old != null && old != dest.path) {
        final oldFile = File(old);
        await FileImage(oldFile).evict();
        try {
          if (oldFile.path.startsWith(dir.path) && await oldFile.exists()) {
            await oldFile.delete();
          }
        } catch (_) {/* 删不掉就算了 */}
      }
    } catch (e) {
      // 用户点"取消"不会走到这里；这里是权限被拒、文件读不到之类的真错误。
      // 原始原因对用户没意义，只进日志；界面上给一句他能照做的：换一张。
      debugPrint('选图失败: $e');
      if (!mounted) return;
      _toast('这张图片读取失败，换一张试试');
    }
  }

  /// 方案的小样：底色 + 两团最有代表性的调子色压成一个圆。
  ///
  /// 只用 `RadialGradient` 近似，不重画真正的色斑 —— 34px 的圆里摆六团按屏幕比例
  /// 定半径的色斑毫无意义，能看出"这套偏暖还是偏冷、整体多深"就够了。
  ///
  /// ⚠ **小样必须跟着当前深浅色走。** 这里原来固定用 `s.base`（浅色底色），于是深色
  /// 模式下两张小样都是亮的：用户看到「默认」是一个灰白的圆，选中之后整片却是黑底，
  /// 小样和实际对不上（用户实测提过这一点）。
  Widget _bgSwatch(BackdropStyle s) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? s.darkBase : s.base;
    // 深色下色斑是"压上来的白光"，强度按方案给 —— 跟 `_BackdropPainter` 同一套逻辑，
    // 所以「默认」的小样在深色下也是一个黑圆（而不是灰的）。
    Color over(Color tone, double o) => Color.alphaBlend(
          dark ? Colors.white.withOpacity(o * s.darkBlobScale) : tone.withOpacity(o),
          base,
        );
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0x22000000)),
        gradient: RadialGradient(
          center: const Alignment(-0.4, -0.5),
          radius: 1.15,
          colors: [
            over(s.tones[2], 0.55),
            base,
            over(s.tones[5], 0.45),
          ],
          stops: const [0.0, 0.62, 1.0],
        ),
      ),
    );
  }

  // ---------- 课表 ----------

  Future<void> _pickTerm() async {
    if (_terms.isEmpty) return;
    final v = await _pickOption('选择学期', _terms, _term);
    if (v != null) {
      setState(() => _term = v);
      await SchedulePrefs.instance.setTerm(v); // 通知课表页重载
    }
  }

  Future<void> _pickCampus() async {
    if (_campuses.isEmpty) return;
    final v = await _pickOption('选择校区', _campuses, _campus);
    if (v != null) {
      setState(() => _campus = v);
      await SchedulePrefs.instance.setCampus(v);
    }
  }

  Future<String?> _pickOption(
      String title, List<SelectOption> opts, String? current) {
    final theme = Theme.of(context);
    return showGlassSheet<String>(
      context: context,
      builder: (_) => ListView(
        shrinkWrap: true,
        children: [
          _sheetTitle(title),
          ...opts.map((o) => ListTile(
                title: Text(o.label),
                trailing: o.value == current
                    ? Icon(Icons.check, color: theme.colorScheme.primary)
                    : null,
                selected: o.value == current,
                onTap: () => Navigator.pop(context, o.value),
              )),
        ],
      ),
    );
  }

  String _labelOf(List<SelectOption> opts, String? value, String fallback) {
    if (value == null) return fallback;
    for (final o in opts) {
      if (o.value == value) return o.label;
    }
    return fallback;
  }

  // ---------- 关于 ----------

  /// 「检查更新」一条。
  ///
  /// 进这页时已经静默查过一次：查到新版就在这条上挂个提示，查不到就只显示当前
  /// 版本号。用户主动点时才有弹窗反馈。
  Widget _updateTile() {
    final scheme = Theme.of(context).colorScheme;
    final up = _update;
    return ListTile(
      leading: Icon(
        up == null ? Icons.system_update_alt : Icons.new_releases,
        color: up == null ? null : scheme.primary,
      ),
      title: const Text('检查更新'),
      subtitle: up == null ? null : Text('发现新版本 ${up.version}'),
      trailing: _checkingUpdate
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(
              AppInfo.version,
              style: TextStyle(
                  color: up == null ? scheme.onSurfaceVariant : scheme.primary),
            ),
      onTap: _checkingUpdate
          ? null
          : (up == null ? _manualCheckUpdate : () => _offerUpdate(up)),
    );
  }

  /// 进这页时静默查一次。任何失败都当作"没有更新"，不弹任何东西。
  Future<void> _checkUpdate() async {
    final info = await UpdateService.check();
    if (!mounted) return;
    setState(() => _update = info);
  }

  /// 用户主动点的那次：这次要有反馈，不能像进页时那样静默
  Future<void> _manualCheckUpdate() async {
    setState(() => _checkingUpdate = true);
    final info = await UpdateService.check();
    if (!mounted) return;
    setState(() {
      _checkingUpdate = false;
      _update = info;
    });
    if (info == null) {
      _toast('已是最新版本（${AppInfo.version}）');
      return;
    }
    await _offerUpdate(info);
  }

  /// 提示有新版本，并给出下载入口。
  ///
  /// 不在 App 里下载安装：Android 要申请「安装未知应用」权限，iOS 的未签名
  /// IPA 又必须走 TrollStore。两条路都丢给系统浏览器最省事，也最不容易出错。
  Future<void> _offerUpdate(UpdateInfo info) async {
    final url = UpdateService.downloadUrlFor(info);
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
        if (url != null)
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              _openDownload(url);
            },
            child: const Text('去下载'),
          ),
      ],
    );
  }

  Future<void> _openDownload(String url) async {
    try {
      // 不用 canLaunchUrl：它在 Android 11+ 要在 manifest 里声明 <queries>，
      // 直接 launch、失败就 catch，能省掉一处平台配置。
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok && mounted) _toast('打不开浏览器，请手动访问：$url');
    } catch (_) {
      if (mounted) _toast('打不开浏览器，请手动访问：$url');
    }
  }

  // 「退出登录」搬去「我的」页了（连同它的确认框）。理由：它属于"我是谁"这个话题的
  // 终点，而那一页本来就在显示登录状态，退完就地刷成未登录态，不用再切回来。
  // 另外「数据来源」也搬过去了 —— 那是一句纯展示的说明，不是可改的开关。

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- 骨架 ----------

  Widget _sheetTitle(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
      );

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  // ---------- 入场 ----------
  //
  // 入场动画 = 每行往上挪 8px，按序号依次错开。
  //
  // ⚠ **这里故意没有淡入（Opacity）。** 原来有：opacity 0→1 配位移，总时长 460ms。
  // 实机 iOS 上用户报了两件事 ——「点进新页面会先看到上一个页面一闪而过」和
  // 「动画延迟卡顿」，两件都出在这个淡入上：
  //
  //  * 页面背景是**透明**的（`GlassBackdrop` 画在整个 Navigator 后面，见 main.dart），
  //    所以新页面在推入转场那几百毫秒里几乎**整页全透明** —— 眼睛看到的就是那个还在
  //    退场的上一个页面，然后内容才"加载"出来。这不是转场慢，是新页面当时真的没画东西。
  //  * 每一行的 `Opacity` 都是一次 `saveLayer`，一屏七八行就是七八次。iOS 上这个很贵。
  //
  // 位移留着（`Transform` 比 `saveLayer` 便宜得多），翻页照样有层次，
  // 但**第一帧就是有内容的** —— 这才是"不闪上一个页面"的关键。
  static const Duration _enterTotal = Duration(milliseconds: 260);
  static const Duration _enterStep = Duration(milliseconds: 18);
  static const int _enterMaxStep = 4;

  List<Widget> _entered(List<Widget> children) {
    final out = <Widget>[];
    var i = 0;
    for (final c in children) {
      if (c is SizedBox || c is Divider) {
        out.add(c);
      } else {
        out.add(_enter(i++, c));
      }
    }
    return out;
  }

  Widget _enter(int i, Widget child) {
    final total = _enterTotal.inMilliseconds.toDouble();
    final step =
        _enterStep.inMilliseconds * (i < _enterMaxStep ? i : _enterMaxStep);
    final start = step / total;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: _enterTotal,
      curve: Interval(start, 1, curve: Curves.easeOut),
      builder: (_, t, inner) => Transform.translate(
        offset: Offset(0, 8 * (1 - t)),
        child: inner,
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // 二级页，留玻璃顶栏和返回键 —— 它需要一条"能认出来的边界"
      appBar: AppBar(title: const Text('设置')),
      body: Builder(
        builder: (ctx) {
          final media = MediaQuery.of(ctx);
          return RefreshIndicator(
            onRefresh: _loadOptions,
            edgeOffset: media.padding.top,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: media.padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _entered([
                  const SizedBox(height: 8),
                  _sectionTitle('外观'),
                  _themeTile(),
                  _backgroundTile(),
                  _sectionTitle('课表'),
                  ListTile(
                    leading: const Icon(Icons.calendar_month),
                    title: const Text('学期'),
                    subtitle: _canPick ? null : const Text('登录后可选'),
                    trailing: Text(_labelOf(_terms, _term, '默认'),
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                    onTap: _terms.isEmpty ? null : _pickTerm,
                  ),
                  ListTile(
                    leading: const Icon(Icons.location_city),
                    title: const Text('校区'),
                    subtitle: _canPick ? null : const Text('登录后可选'),
                    trailing: Text(_labelOf(_campuses, _campus, '默认'),
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                    onTap: _campuses.isEmpty ? null : _pickCampus,
                  ),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('刷新'),
                    onTap: _loadOptions,
                  ),
                  _sectionTitle('关于'),
                  _updateTile(),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('关于'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AboutPage()),
                    ),
                  ),
                  const SizedBox(height: 16),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}