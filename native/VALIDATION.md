# 原生版构建验证

日期：2026-11-04，Asia/Shanghai。原生版本 3.0.0（20）。

- 源码：`4759c95b92c6d20e721039a5e26c725afc395776`。
- [成功云构建](https://github.com/qiu7c/GM-Helper/actions/runs/41845323841)。
- [草稿 PR #1](https://github.com/qiu7c/GM-Helper/pull/1)，尚未合并或发布 Release。

## Android

云端执行 `testDebugUnitTest lintDebug assembleDebug assembleRelease`，BUILD SUCCESSFUL。

8 项 JUnit，0 失败、0 忽略。验证脱敏样例解析、空周/异常表、校历、学籍、会话失效分类、同范围调课与周次集合、三校区作息。

Lint 无阻塞错误，仍有系统 API 弃用、图标位置/形状、文字国际化等警告。没有为消除警告引入额外框架。

| 产物 | 实测字节 | MiB | 安装身份 |
| --- | ---: | ---: | --- |
| Android preview APK | 1,422,490 | 1.357 | 已签名预览包，`.nativepreview` 后缀，可与旧版并存 |
| Android Release APK | 347,450 | 0.331 | 未签名，沿用原包名，正式覆盖前需原签名 |
| iOS Release IPA | 2,405,363 | 2.294 | 未签名，需要自行侧载签名 |

APK 实物检查：Manifest 主 Activity/Receiver/Provider 与真实原生类一致，Release DEX 273,280 字节；无 libflutter 或 flutter_assets。这里是压缩安装文件大小，不是安装后占用。

预览签名由此次云 runner 的 Debug 密钥生成，不保证下一次构建相同；不同 Debug 签名的预览包可能需要卸载重装。正式版本必须沿用稳定原签名，不能用预览包验证旧版升级迁移。

## iOS

真实 Xcode Release 编译与未签名 IPA 打包通过。模拟器 XCTest 执行 16 项，0 失败；日志明确 TEST SUCCEEDED。测试覆盖账号/周缓存隔离、空周、登录/维护、单双周、多门课、课程备注、调课差异、Cookie 身份与候选会话隔离、真实日期提醒与 60 条上限、忙碌期间操作、校历与旧更新清单。

最终 IPA 实物检查：bundle ID `cn.gdgm.schedule.gdgmSchedule`，版本 `3.0.0`，最低 iOS `15.0`，不含 Flutter.framework。

本次构建和测试只使用合成数据，没有把学校密码、Cookie 或用户课表上传到 CI。

## 仍需真机验收

- 两端学校网页登录、验证码手动接管、企业微信扫码及 Cookie 持久化。
- 相同学期/周次/校区与旧 App 的实际课表逐项对照。
- 离线、会话自然过期、主动退出、切换账号与本地提醒。
- 相册背景、图片分享、安全区、深色模式与不同屏幕布局。
- 原签名/原 bundle 容器下的旧版覆盖升级与数据迁移。

此前独立协议验证程序在本机成功取得真实课表，只能证明学校协议可行，不能替代上面的原生设备验收。服务器自动抓取和 Bark 已取消。
