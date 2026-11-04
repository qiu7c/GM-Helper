# 广贸课表 iOS 原生版

SwiftUI / UIKit / WebKit，最低 iOS **15.0**。版本 **3.0.0 (20)**，工程名与 shared scheme 均为 `GMSchedule`。

## 打开与构建

用 **Xcode 16 或更新版本**打开 `GMSchedule.xcodeproj`。SwiftSoup 固定官方 tag **2.13.5**，通过 Swift Package Manager 获取；该依赖的 Package.swift 使用 Swift tools 6.0，因而需要 Xcode 16。应用代码采用 Swift 5 语言模式。依赖来源：[SwiftSoup 官方仓库](https://github.com/scinfu/SwiftSoup/tree/2.13.5)，MIT 许可证。

Bundle ID 为 `cn.gdgm.schedule.gdgmSchedule`。旧 IPA 的实际 bundle ID、签名 Team 和 Keychain access group 在当前工作环境尚未实物验证；请在覆盖安装旧版本前核实，不能据此承诺旧容器可访问。普通安装需要在 Signing & Capabilities 选择自己的开发团队；工程不含签名证书、描述文件和账号凭据。

```sh
xcodebuild -resolvePackageDependencies -project native/ios/GMSchedule.xcodeproj -scheme GMSchedule
xcodebuild -project native/ios/GMSchedule.xcodeproj -scheme GMSchedule -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
# 先通过 xcrun simctl list devices available 选出 runner 实际已有的模拟器 UUID。
xcodebuild -project native/ios/GMSchedule.xcodeproj -scheme GMSchedule -destination 'platform=iOS Simulator,id=模拟器UUID' CODE_SIGNING_ALLOWED=NO test
# 无签名真机应用，仅供之后由合法签名工具处理；不是已签名可安装 IPA。
xcodebuild -project native/ios/GMSchedule.xcodeproj -scheme GMSchedule -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO build
```

`generate_project.py` 可以用 Python 3 标准库重新生成已经纳入目录的 `.xcodeproj` 和 shared scheme。图标已经从项目 `assets/icon/app_icon.png` 转换为 18 个不含透明通道的尺寸，Windows 下可用 `build_icons.ps1` 重建。工程资源不依赖 Flutter、服务器或其他平台目录。

## 功能与数据路径

- 登录主路径是学校 WKWebView 网页，支持原生账号/密码自动填入、系统密码建议、用户选择保存密码、自动登录一次尝试、验证码手动处理与企业微信扫码/唤起。学校网页执行自己的密码加密脚本，不在应用里复刻或绕过验证码。
- 门户成功后在同一个网页会话打开 `appShow?appId=5759540940956162`；由 `sso.jsp` 脚本执行第二次 CAS service 授权。只有 URLSession 验证教务主框架和取得真正学号后才结束登录。Cookie 存在不等于登录成功。
- 手机 URLSession 直接请求学校的课表、桌面校历与学籍 HTML，SwiftSoup 解析。网络响应只在该入口判状态、登录页和业务结构；无完整 `kbtable` 或无节次行拒绝覆盖缓存。真实有表无课程的周正常缓存。
- 周课表、上/下周、周次滚轮、日期跳周、回本周、学期与天河/白云/荔湾校区选择；荔湾没有第六大节。当前/下节状态每 30 秒更新，只使用已有缓存；校历按学期绑定。
- 账号、学期、校区、周共同确定缓存范围，最多 6 份。先显示该范围缓存再联网。只有相同范围的数据互相比对变化。断网/掉会话不清缓存；主动退出清除全部课表缓存、内存学籍与通知，并禁止本次运行再次自动登录。
- 课程点击/长按查看详情与编辑备注，备注按账号隔离；学籍页、系统/浅色/深色主题、4 个背景预设、相册自定义背景及模糊；课表图片使用固定浅色渲染并通过系统分享，可在系统分享面板保存。
- 本地课前通知只在用户开关打开时请求系统权限。根据匹配账号/学期/校区的已缓存课表，使用具体年月日及上海时区，至多安排未来 60 条，不重复每周提醒。**关闭 App 后不会自行向学校取新课表**；缓存最多 6 周，需定期打开刷新。开关、刷新、切换范围、退出会重建或清理通知。
- 每次启动检查公开 GitHub `latest.json`，只在版本比 3.0.0/20 新时提示；设置中可手动检查，通过系统浏览器打开清单中的 HTTPS IPA 下载地址。旧 2.2.7 清单不会提示降级。未加入服务器轮询、Bark、推送服务或自动安装。
- 日志只保留当前进程最多 100 条操作摘要，不记录账号、密码、Cookie、HTML 或带 ticket 的 URL。

## 存储与旧版兼容

密码仅在用户选择且成功认证后保存到 Keychain（WhenUnlockedThisDeviceOnly）；关闭保存密码会删除。Cookie 将完整属性序列化后存 Keychain，保留 domain/path/name/expiry/secure，避免把不同域同名 Cookie 合并。URLSession 使用 ephemeral Cookie jar，WKWebView 使用 nonPersistent store，持久凭据只写 Keychain。

UserDefaults 保存偏好、课表缓存和按账号隔离的备注；自定义背景写 Application Support 并启用 complete file protection。无账号示例、真实密码或个人服务器数据随工程打包。

在**同一应用容器可访问**的前提下尝试读取 `flutter.` 前缀的用户名、学期、校区、主题、背景预设/模糊和 `schedule_cache_v1`。缓存只导入具有完整账号/学期/校区/周键以及有效节次的数据，并保持最多 6 份。旧明文 password 和扁平 Cookie 不导入，迁移完成后删除其旧 UserDefaults 项，用户需重新登录。

旧版 `course_notes` 没有账号归属，因此不会自动分配给当前用户；「我的 → 旧版备注」提供用户明确选择后导入当前账号的入口。旧版背景绝对路径、其他 bundle 的容器、旧 Keychain access group 和完整旧版存储覆盖安装迁移均**未验证**，不能声称迁移全部完成。

## 验证状态

本地 Windows 的 Swift 语法与工程结构检查通过。随后代码 `4759c95` 已在 [GitHub macOS 云构建](https://github.com/qiu7c/GM-Helper/actions/runs/41845323841)完成真实 Xcode Release 编译、未签名 IPA 打包，以及 16 项模拟器 XCTest（0 失败）。这不等于真机验收。

`GMScheduleTests` 含合成 HTML / 虚构凭据测试：奇偶周、多课程解析、真空周与缺表、会话/维护区分、三校区时间、缓存 6 份与账号/周隔离、同范围变更比较、账号备注、Cookie domain/path、提醒日期与 60 条限制、校历、旧更新清单不提示。运行测试不需要学校账号。

真机还需验收：账号密码/验证码/企业微信完整授权、学校实时 HTML、覆盖安装容器兼容、iOS 15 布局与深色模式、照片选择、分享图片、关闭 App 后通知、学校掉会话与离线缓存。企业微信需要设备安装对应客户端或使用可扫描的网页二维码。
