# GMPluse 原生版

Android（Kotlin / 系统 View）与 iOS（Swift / SwiftUI）为两个独立原生工程，版本 3.0.1（21）。原 Flutter 工程保留用于功能对照。

- Android：`android/`，最低 Android 8.0（API 26），target 35。
- iOS：`ios/GMSchedule.xcodeproj`，最低 iOS 15（已由用户确认），shared scheme `GMSchedule`。
- 脱敏的解析与业务验收样例：`fixtures/`。其中不含真实用户课表、Cookie 或密码。
- 功能矩阵：`FEATURE_PARITY.md`。源码实现不等于已通过真机验收。

手机直接访问学校认证、门户和教务系统。账号密码在自绘原生登录页输入，通过 HTTP 完成 CAS 加密登录与两次教务授权；正常登录不创建网页。只有学校要求验证码或用户主动选择扫码时打开 WebView/WKWebView，验证码继续同一候选会话。课表与学籍由客户端请求和解析；会话过期或断网保留课表，主动退出清除课表会话。缓存按账号、学期、校区和周次区分，正常空周可以缓存。课程备注按账号隔离。课程颜色按账号和课程名持久保存，详情中可选 8 种颜色，与标题长度无关。

服务器自动获取课表及 Bark 已取消。本地提醒只针对本机已经获取的课表；App 关闭期间不会自动发现学校调课。手机网络也必须能访问学校。

## 构建

GitHub Actions `Native Android and iOS` 为 `native/rewrite` 分支代码推送自动验证。工作流合并进入默认分支后，也可手动运行（[GitHub 的默认分支要求](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)）。不会调用原 Flutter 的发布步骤，不会自动发布 Release。

iOS 云编译使用 macOS runner，构建未签名 IPA 并运行模拟器 XCTest。未签名 IPA 需要自行签名/现有侧载工具安装，不包含 Apple 开发者证书。

Android 云编译运行 JUnit、Lint、Debug 与 Release 构建。Debug 使用 `.nativepreview` 包名后缀，可以与旧版并存；Release 沿用原包名，但没有自动套用旧仓库的签名密钥，因此默认是未签名产物。正式覆盖安装需要使用原发布签名；不能用预览包证明覆盖安装或旧数据迁移成功。

## 旧数据

两端都提供一次性旧偏好/缓存迁移入口，只有相同应用身份和保留沙盒时才可能生效。迁移是否成功必须通过旧版升级真机测试。

Android 保存密码时使用 Android Keystore 中的 AES-GCM 密钥，WebView Cookie 保存在系统提供的 App 私有存储，禁止系统备份。iOS 凭据和结构化 Cookie 使用 Keychain。用户没有选择保存密码时，不持久化密码。

## 当前验证状态

代码 `685e629` 的[云构建](https://github.com/qiu7c/GM-Helper/actions/runs/41947891633)两端通过：Android 13 项单元测试、Lint、Debug/Release 构建；iOS 22 项模拟器 XCTest、Release 编译、未签名 IPA 打包。详细结果与限制见 `VALIDATION.md`；真机登录、验证码、提醒和旧版升级尚待验收。

界面采用简洁布局与图标+文字的悬浮底栏。周课表以首屏五大节为基准，第六节可滑动查看。课程名与教室完整换行，长内容可撑高整行，七列保持等高；多课同格可点选全部课程，导出图片使用独立的大尺寸排版。主题选择、背景预设、自定义背景图片与模糊功能已移除，应用跟随系统明暗模式。
