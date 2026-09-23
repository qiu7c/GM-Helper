import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 更新日志：读的是打进包里的 CHANGELOG.md。
///
/// 没引 markdown 库 —— 更新日志只用到「## 标题 / - 条目 / 普通段落 / > 引用」
/// 这几种写法，自己拆一下比多背一个依赖划算（也免得再纠结渲染样式）。
class ChangelogPage extends StatefulWidget {
  const ChangelogPage({super.key});

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  late final Future<String> _text = _load();

  Future<String> _load() async {
    try {
      return await rootBundle.loadString('CHANGELOG.md');
    } catch (_) {
      // 理论上不会发生（pubspec 里声明了）。真读不到也别给个白屏。
      return '读不到更新日志。';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('更新日志')),
      body: FutureBuilder<String>(
        future: _text,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return _render(context, snap.data ?? '');
        },
      ),
    );
  }

  Widget _render(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    final blocks = <Widget>[];

    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.startsWith('## ')) {
        blocks.add(Padding(
          // 第一段标题不额外留顶空
          padding: EdgeInsets.only(top: blocks.isEmpty ? 0 : 22, bottom: 8),
          child: Text(
            line.substring(3).trim(),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: scheme.primary,
            ),
          ),
        ));
      } else if (line.startsWith('- ')) {
        blocks.add(Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 7, right: 8),
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                      color: scheme.primary, shape: BoxShape.circle),
                ),
              ),
              Expanded(
                child: Text(line.substring(2).trim(),
                    style: const TextStyle(height: 1.5)),
              ),
            ],
          ),
        ));
      } else if (line.startsWith('> ')) {
        blocks.add(Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            line.substring(2).trim(),
            style: TextStyle(
                fontSize: 12, color: scheme.onSurfaceVariant, height: 1.5),
          ),
        ));
      } else if (line.startsWith('# ')) {
        // 文件自己的大标题 —— 页面已经有 AppBar 了，跳过
      } else if (line.trim().isEmpty) {
        blocks.add(const SizedBox(height: 8));
      } else {
        blocks.add(Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(line, style: const TextStyle(height: 1.5)),
        ));
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: blocks,
    );
  }
}
