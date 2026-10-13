import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// App 里的「更新日志」页**不做 markdown 解析**（见 `changelog_page.dart` 开头的注释），
/// 只认这几种写法，而且判据是**行首**：
///
///   `## 标题` / `- 条目` / `> 引用` / `# 大标题`（跳过）/ 空行 / 其余当普通段落
///
/// 于是下面这些会**静默**渲染错，不报错、不崩，只是难看 —— 所以只能靠测试拦：
///
///   * `  - 子条目`：行首是空格不是 `- `，掉进"普通段落"，**连减号一起原样显示**；
///   * `**加粗**`：星号原样显示；
///   * `### 小标题`：没人处理，连井号一起显示。
///
/// 这段还会被 CI 抽出来当 GitHub release 的正文，所以本来就该短。
/// 这条测试是 2.2.4 写出一坨之后补的 —— 那一版就是踩了前两条。
void main() {
  test('CHANGELOG 只用 App 能渲染的写法', () {
    final file = File('CHANGELOG.md');
    expect(file.existsSync(), isTrue, reason: 'CHANGELOG.md 应该在包根目录');

    final problems = <String>[];
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final line = raw.trimRight(); // 渲染时也只去右侧空白
      if (line.isEmpty) continue;

      if (line != raw.trimLeft() && (line.trimLeft().startsWith('- ') ||
          line.trimLeft().startsWith('> '))) {
        problems.add('第 ${i + 1} 行是嵌套子条目/缩进引用，'
            'App 里会连符号一起当普通文字显示');
      }
      if (line.contains('**')) {
        problems.add('第 ${i + 1} 行含 ** 加粗，App 里会原样显示星号');
      }
      if (line.startsWith('### ')) {
        problems.add('第 ${i + 1} 行是三级标题，App 里不认识，会连井号一起显示');
      }
    }

    expect(problems, isEmpty, reason: '\n${problems.join('\n')}');
  });

  test('CHANGELOG 的每一版都不至于长到没人看', () {
    final lines = File('CHANGELOG.md').readAsLinesSync();
    // 按 `## ` 切段，看每一段多少行（含标题）
    final sizes = <String, int>{};
    String? cur;
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.startsWith('## ')) {
        cur = line.substring(3).trim();
        sizes[cur] = 1;
      } else if (cur != null && line.isNotEmpty) {
        sizes[cur] = sizes[cur]! + 1;
      }
    }
    // 12 行 = 一大段就说明在写小作文了。理由：这段同时是 release 正文，
    // 用户是按条扫的，不是按段读的。
    final tooLong = sizes.entries.where((e) => e.value > 12).toList();
    expect(tooLong, isEmpty,
        reason: '这几版太长了，用户不会读：'
            '${tooLong.map((e) => '${e.key}(${e.value} 行)').join('、')}');
  });
}