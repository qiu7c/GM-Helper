# GMPluse

广东工贸职业技术学院校园助手（Flutter · Android / iOS）。当前已实现课表查看与学籍信息，后续会拓展更多功能。

## 功能

- **账号密码登录**：在自绘页面输入账号密码，由内嵌 WebView 自动填入认证网页的两个输入框并提交（等价于模拟人手动输入），加密/跳转/Cookie 全交给浏览器内核；页面保持可见，遇到验证码可直接接管。另提供一条不打开网页的纯 HTTP 直连登录作为备用。
- **课表**：顶部周次导航（◀ 第 N 周 ▶ / 点选 / 按日期跳周），当前周与总周数直接读取教务系统真实校历，今天列高亮。
- **我的**：展示姓名、学号、院系、专业、班级等信息；可切换学期 / 校区（改后课表自动重载）；退出登录。
- **校区大节时间**：天河 / 白云 / 荔湾各自的作息时间（荔湾无第六大节）。

## 原理

1. CAS 登录：GET 登录页取动态令牌与加密盐 → AES 加密密码 → POST 提交 → 逐跳跟随 302，经 eportal 门户握手 → 给教务系统 `jw.gdgm.cn` 种下会话 Cookie。
2. 用会话 Cookie 请求教务接口，解析 HTML 得到课表、学籍、校历。

## 目录结构

```
lib/
  config.dart                     网址、大节时间等配置
  main.dart                       入口
  models/course.dart              课程 / 学期日历数据模型
  services/auth_store.dart        Cookie / 偏好本地存储
  services/cas_login_service.dart 纯 HTTP 模拟 CAS 登录
  services/schedule_service.dart  请求 + 解析课表 / 校历
  services/profile_service.dart   解析学籍信息
  services/schedule_prefs.dart    学期 / 校区 / 校历全局状态
  pages/password_login_page.dart  自绘账号密码登录
  pages/login_page.dart           WebView 登录（兜底）
  pages/timetable_page.dart       课表界面
  pages/profile_page.dart         我的
  pages/about_page.dart           关于
  pages/home_shell.dart           底部导航
assets/icon/                      App 图标源与生成图
.github/workflows/build.yml       GitHub Actions 云打包
```

> 当前周 / 总周数由教务系统实时提供，无需再手动配置开学日期。

## 用 GitHub 云打包（无需本地装 Flutter）

push 到 `main` 后，仓库 **Actions** 会自动构建；也可在 Actions 页面手动触发 **Build App → Run workflow**。

构建产物在对应运行页底部 **Artifacts**：
- `gdgm-schedule-apk` → `app-release.apk`，安卓直接安装。
- `gdgm-schedule-ipa-unsigned` → 未签名 iPhone 包，需 TrollStore / AltStore / Sideloadly 等侧载自签。

> iOS 因苹果签名限制，云端只能出未签名包；正式上架仍需 Mac + Apple 开发者账号。

## 本地运行（可选，需已装 Flutter）

```bash
flutter create --platforms=android,ios .
flutter pub get
dart run flutter_launcher_icons   # 生成 App 图标
flutter run
```

## 反馈

使用中遇到 bug 或想提新功能，见 App 内「我的 → 关于」的联系方式。
