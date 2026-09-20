import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 关于页：版本、联系方式、使用声明
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const String version = '1.0.1';
  static const String author = 'cc';
  static const String email = 'xcc575838@gmail.com';
  static const String qq = '921569084';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        children: [
          const SizedBox(height: 32),
          Image.asset('assets/icon/app_logo.png', width: 88, height: 88),
          const SizedBox(height: 12),
          const Center(
            child: Text('GMPluse',
                style:
                    TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 4),
          const Center(
            child: Text('版本 $version',
                style: TextStyle(color: Colors.grey)),
          ),
          const SizedBox(height: 32),
          const ListTile(
            leading: Icon(Icons.person_outline),
            title: Text('作者'),
            trailing: Text(author),
          ),
          _copyTile(context, Icons.email_outlined, '邮箱', email),
          _copyTile(context, Icons.chat_bubble_outline, 'QQ', qq),
          const ListTile(
            leading: Icon(Icons.tag),
            title: Text('版本号'),
            trailing: Text(version),
          ),
          const ListTile(
            leading: Icon(Icons.build_outlined),
            title: Text('开发技术'),
            subtitle: Text('基于 Flutter 开发，支持 Android / iOS；'
                '通过统一身份认证登录，直连教务系统获取课表与学籍数据'),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('使用声明',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              '本应用仅供自己使用，用于查看个人课表，不用于任何商业用途。'
              '课表及学籍数据均来自广东工贸职业技术学院教务系统，'
              '仅在本机展示，不上传任何第三方服务器。',
              style: TextStyle(color: Colors.grey, height: 1.6),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('反馈与建议',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Text(
              '使用中遇到 bug，或想提新功能，都欢迎通过上方的邮箱 / QQ 联系我反馈。',
              style: TextStyle(color: Colors.grey, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _copyTile(
      BuildContext context, IconData icon, String label, String value) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(value),
      trailing: const Icon(Icons.copy, size: 18, color: Colors.grey),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已复制$label：$value')),
          );
        }
      },
    );
  }
}
