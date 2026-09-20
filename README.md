# 广工贸课表 App

查看广东工贸职业技术学院教务系统课表的 Flutter App（Android / iOS）。

原理：App 内嵌浏览器完成 eportal 统一身份认证登录 → 抓取会话 Cookie →
用 Cookie 请求教务系统课表接口 `xskb_list.do` → 解析成原生课表界面。

## 目录结构

```
lib/
  config.dart                 网址、学期起始日等配置（★需按校历改）
  main.dart                   入口
  models/course.dart          课程数据模型
  services/auth_store.dart    Cookie 本地存储
  services/schedule_service.dart  请求 + 解析课表 HTML
  pages/login_page.dart       WebView 登录、抓 Cookie
  pages/timetable_page.dart   原生课表界面
  widgets/course_colors.dart  课程配色
.github/workflows/build.yml   GitHub Actions 云打包
```

## ★ 打包前必改

打开 `lib/config.dart`，把 `termFirstMonday` 改成**本学期第 1 周周一的真实日期**，
否则 App 自动计算的「当前第几周」会错。

```dart
static DateTime termFirstMonday = DateTime(2026, 8, 31); // 改成你的校历
```

## 用 GitHub 云打包（无需本地装 Flutter）

1. 在 GitHub 新建一个仓库（例如 `gdgm-schedule`）。
2. 把本项目 `gdgm_schedule/` 里的所有文件推上去：
   ```bash
   cd gdgm_schedule
   git init
   git add .
   git commit -m "init"
   git branch -M main
   git remote add origin https://github.com/你的用户名/gdgm-schedule.git
   git push -u origin main
   ```
3. push 后，仓库的 **Actions** 标签页会自动开始构建。
   也可以在 Actions 页面点 **Build App → Run workflow** 手动触发。
4. 构建完成后（约 5-10 分钟），进入那次运行，在页面底部 **Artifacts** 下载：
   - `gdgm-schedule-apk` → 解压得到 `app-release.apk`，安卓直接安装。
   - `gdgm-schedule-ipa-unsigned` → 未签名 iPhone 包，需用 AltStore / Sideloadly
     等工具侧载自签（无 Mac、无开发者账号时的折中方案）。

> Android 打出来的是 release APK，可直接装。iOS 因为苹果签名限制，云端只能出
> 未签名包，正式上架仍需 Mac + Apple 开发者账号。

## 本地运行（可选，需已装 Flutter）

```bash
cd gdgm_schedule
flutter create --platforms=android,ios .
flutter pub get
flutter run
```

## 常见问题

- **登录后一直转圈 / 抓不到 Cookie**：教务系统登录成功的判定地址在
  `config.dart` 的 `loginSuccessMarkers`，若学校改版跳转地址变了，按实际改。
- **课表空白**：确认周次选对；或点右上角菜单「显示全部周」看是否有数据。
- **提示会话失效**：Cookie 过期属正常，重新登录即可。
```
