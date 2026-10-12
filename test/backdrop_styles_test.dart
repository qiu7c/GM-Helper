import 'package:flutter_test/flutter_test.dart';
import 'package:gdgm_schedule/services/schedule_prefs.dart';
import 'package:gdgm_schedule/widgets/app_theme.dart';
import 'package:gdgm_schedule/widgets/glass_backdrop.dart';

/// `BackdropStyle` 这个类有一半的约束没法写在 `const` 构造函数的 `assert` 里
/// （`List.length` 不是常量表达式，编译期直接报 `const_eval_property_access`），
/// 所以那些约束挪到这里守。
void main() {
  test('每个方案的调子色都是六个', () {
    for (final s in kBackdropStyles) {
      expect(
        s.tones.length,
        6,
        reason: '方案 ${s.id}（${s.label}）的 tones 不是六个 —— 画色斑时会越界',
      );
    }
  });

  test('方案 id 唯一', () {
    // id 是直接存进 SharedPreferences 的值，重复的话用户选中的会被取成另一个
    final ids = kBackdropStyles.map((s) => s.id).toList();
    expect(ids.toSet().length, ids.length, reason: '有重复的 id：$ids');
  });

  test('未知 id 退回第一套，不抛异常', () {
    // 用户装过更新的版本又降级回来时，SP 里可能留着这边不认识的 id
    expect(backdropStyleOf(9999).id, kBackdropStyles.first.id);
    expect(backdropStyleOf(-1).id, kBackdropStyles.first.id);
  });

  test('id 0 的语义不再变（它以前是「经典」）', () {
    // id 0 原来是「经典」。老用户存的 0 会变成冷岩 —— 这是有意改掉的。
    // ⚠ 它**不再是"没设置过"时的默认值**（那个现在是 id 1，见下一条），
    // 但 0 这个数字本身不能挪作他用，否则老用户的背景会被换掉。
    expect(kBackdropStyles.first.id, 0);
    expect(kBackdropStyles.first.label, '冷岩');
  });

  test('全新安装的默认是「默认」这一套（id 1）', () {
    // 名字叫「默认」的那套得真的是默认值。这里原来是 0（冷岩）—— 名字和默认值对不上，
    // 用户会以为选错了。已经选过背景的用户存的是数字，不受影响。
    expect(kDefaultBackdropId, 1);
    expect(backdropStyleOf(kDefaultBackdropId).label, '默认');
    // 这个 id 必须真的存在（写错数字会走 backdropStyleOf 的兜底，悄悄变回冷岩）
    expect(kBackdropStyles.any((s) => s.id == kDefaultBackdropId), isTrue);
  });

  test('「默认」是纯白/纯黑，不带任何色斑', () {
    // 这一档的语义就是"什么都没有"：浅色一张白纸、深色一张黑纸。
    final plain = backdropStyleOf(1);
    expect(plain.base.value, 0xFFFFFFFF, reason: '「默认」浅色必须是纯白');
    for (final t in plain.tones) {
      expect(t.value, 0xFFFFFFFF,
          reason: '「默认」浅色的六个调子色必须也是纯白 —— 和底色不同就会有淡灰斑');
    }
    expect(plain.darkBase.value, 0xFF000000, reason: '「默认」深色必须是纯黑');
    expect(plain.darkBlobScale, 0,
        reason: '「默认」深色不该压白斑。给 0.08 时整片会被抬到 0.06 亮度 —— 那是炭灰不是黑');
  });

  test('深色下的色斑强度按方案给：冷岩有、默认没有', () {
    // 回归：深色模式下图色斑的代码原来**完全不看方案**（永远 `Colors.white` ×
    // 固定 0.40）。于是两套方案在深色里长得一模一样 —— 用户反馈"默认的深色底用的
    // 还是冷岩那一套"。
    for (final s in kBackdropStyles) {
      expect(s.darkBlobScale, greaterThanOrEqualTo(0),
          reason: '方案 ${s.id}（${s.label}）深色强度不能为负');
      expect(s.darkBlobScale, lessThanOrEqualTo(0.5),
          reason: '方案 ${s.id}（${s.label}）深色色斑太强，会盖掉 darkBase');
    }
    final plain = backdropStyleOf(1).darkBlobScale;
    final cool = backdropStyleOf(0).darkBlobScale;
    expect(cool, greaterThan(0),
        reason: '冷岩深色必须带色斑，否则整片是纯色、玻璃背后没东西可糊');
    expect(plain, lessThan(cool),
        reason: '「默认」深色要纯黑（不压色斑），冷岩才压（现在 $plain vs $cool）');
  });

  test('退役的 id（2 暖灰 / 3 冷岩）没有被重新启用成别的方案', () {
    // 这两个 id 曾经是「暖灰」和「冷岩」。方案精简掉之后，老配置里存着 2/3 的会走
    // backdropStyleOf 的兜底（＝冷岩）。哪天要是把 2/3 拿去当新方案，那些老用户升级
    // 后就会看到一个从没选过的背景 —— 这条就是拦这个的。
    final ids = kBackdropStyles.map((s) => s.id).toSet();
    expect(ids.contains(2), isFalse, reason: 'id 2 是退役的「暖灰」，不要复用');
    expect(ids.contains(3), isFalse, reason: 'id 3 是退役的「冷岩」，不要复用');
  });

  test('主题种子是纯中性（回归：种子带色相会让底栏选中项泛蓝）', () {
    // **这才是"发蓝"的真正来源。** 背景偏冷是设计（冷岩），但种子一点都不能偏：
    // 种子会渗进 ColorScheme 的每个槽位，底栏选中项、primary、各种 container 全跟着
    // 偏。历史上种子写过 0xFF2A2A2C（蓝比红绿高 2），就是这么翻车的。
    expect(AppTheme.seed.red, AppTheme.seed.green, reason: '种子的 R 与 G 不等');
    expect(AppTheme.seed.green, AppTheme.seed.blue, reason: '种子的 G 与 B 不等');
  });

  test('两套底色都不透明，且「默认」深色是纯黑、和冷岩的深色不同', () {
    // 背景这层是不透明的兜底：页面的 Scaffold 全是透明的，底要是也透明，露出来的
    // 就是窗口底色。深浅两个底色都得满足。
    for (final s in kBackdropStyles) {
      expect(s.base.alpha, 255, reason: '方案 ${s.id}（${s.label}）浅色底色不透明');
      expect(s.darkBase.alpha, 255, reason: '方案 ${s.id}（${s.label}）深色底色不透明');
    }

    // 名字：id 1 原来是「素白」。它在深色下是一张**黑**底，叫素白自相矛盾，
    // 所以改名「默认」。id 不动 —— 存着 1 的老用户看到的是同一套背景。
    final plain = backdropStyleOf(1);
    expect(plain.label, '默认', reason: 'id 1 的名字应该已经从「素白」改成「默认」');
    expect(plain.base.value, 0xFFFFFFFF, reason: '「默认」浅色是纯白');
    expect(plain.darkBase.value, 0xFF000000,
        reason: '「默认」深色下应该是纯黑（浅色白纸 / 深色黑纸）');

    // 深色下两套必须**真的不一样**。原来所有方案共用同一个近黑，切方案在深色里
    // 完全看不出变化 —— 用户提的就是这一条。
    expect(kBackdropStyles.first.darkBase, isNot(plain.darkBase),
        reason: '冷岩和默认的深色底色不能相同，否则深色下选谁都一样');
  });
}