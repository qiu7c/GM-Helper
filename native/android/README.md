# Android 原生版

Kotlin + Android 系统 View，使用 Jsoup 解析 HTML，没有 Flutter 引擎、Compose、WebView 内核打包或数据库依赖。

## 本地

需要 JDK 17 和 Android SDK（platform 35 / build-tools 34.0.0）。Android Studio 可直接打开本目录。

```bash
./gradlew testDebugUnitTest lintDebug assembleDebug assembleRelease
```

Windows 使用 `gradlew.bat`。生成文件在 `app/build/outputs/apk/`。预览版包名 `cn.gdgm.schedule.gdgm_schedule.nativepreview`，Release 包名 `cn.gdgm.schedule.gdgm_schedule`。

默认 Release 不签名。正式升级需用原应用签名处理 APK；项目不会把签名密钥或口令复制到新工程。预览版与旧 App 不共享沙盒。

## 运行与行为

在“我的”登录学校账号。原生表单经 HTTP 读取动态参数、执行学校要求的 AES 加密及两次 CAS 授权，取得学籍和课表后才保存会话。正常登录不展示网页；要求验证码时才带候选 Cookie 打开学校页面。扫码入口保留。

课程颜色按账号和课程名持久保存，详情中可手选 8 色，不再根据名称哈希配色。

支持周次与日期导航、校区与学期选择、先缓存后刷新、空周、差异提示、学籍、课程备注、浅色课表图片分享、GitHub 版本清单检查、本地课前提醒。

本地提醒汇总已缓存的同账号/学期/校区课程，安排最多 60 条未来提醒；手机重启后恢复已保存计划。Android 13+ 需要通知授权；未授予精确闹钟权限时使用系统非精确闹钟，可能延后。它不会在后台联网查调课。

账号偏好和课表是本机私有存储，选择保存的密码用 Keystore AES-GCM 加密。主动退出清理登录、课表缓存、提醒和保存密码；备注仍按账号保留。

## 测试

JUnit 还验证 AES 向量、验证码不提交密码、错误密码只提交一次，以及完整 HTTP 登录和两次 SSO。模拟器截图使用虚构课表，校验自绘登录页与课表实际渲染。JUnit 读取 `../fixtures` 的虚构 HTML，验证完整课表、空周、登录失效、维护页、校历、学籍、调课比较及校区作息。真机仍需检查：网页登录/验证码/扫码，断网缓存，覆盖升级迁移，图片分享目标 App，通知权限和实际提醒，系统深色/安全区。

界面采用简洁布局与图标+文字的悬浮底栏。周课表以首屏五大节为基准，第六节可滑动查看。课程名与教室完整换行，长内容可撑高整行，七列保持等高；多课同格可点选全部课程，导出图片使用独立的大尺寸排版。主题选择、背景预设、自定义背景图片与模糊功能已移除，应用跟随系统明暗模式。
