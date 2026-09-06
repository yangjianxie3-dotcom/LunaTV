# LunaTV iPhone 原生客户端

此目录是独立原生 iOS 客户端，不是网页壳。它直接读取 `config/lunatv-config.json` 或用户填写的远程配置，支持 Wi‑Fi、4G 和 5G，不依赖电脑或电视端运行。

## 已实现功能

- 首页四类最新内容与继续观看
- 电影、剧集、动漫、综艺片库
- 分类、类型、地区、年代（动态包含当前年份）、平台和排序
- 全配置源搜索、详情匹配、响应时间排序与失败自动换源
- 原生全屏播放器、进度拖动、快进/快退、上下集、快速选集、线路切换、适应/铺满
- 收藏、观看记录、自动续播、直播源与频道搜索
- 前台每 10 分钟静默刷新，远程配置失败时保留或回退内置配置
- IPA 下载页、GitHub 发布页或 TestFlight 更新入口

## 在 Mac 上生成工程

需要 macOS、Xcode 及 XcodeGen：

```bash
brew install xcodegen
cd /path/to/lunaTV/ios
xcodegen generate
open LunaTViOS.xcodeproj
```

在 Xcode 的 LunaTV target 中选择自己的 Team。真机调试可使用普通 Apple ID 的 Personal Team；通过 TestFlight、Ad Hoc 或 App Store 长期分发则需要付费 Apple Developer Program 资格。

## 没有付费开发者账号

仓库的 `Validate iOS client` GitHub Actions 工作流会在 macOS 上同时：

1. 编译并验证 iOS 模拟器版本；
2. 生成 `LunaTV-iOS-unsigned.ipa`；
3. 把 IPA 作为工作流 Artifact 保存 30 天。

该 IPA 不能直接点击安装，需在 Windows 上通过 AltStore 使用普通 Apple ID 免费签名。完整步骤见 [INSTALL-FREE-WINDOWS.md](INSTALL-FREE-WINDOWS.md)。

## 验证

```bash
xcodebuild \
  -project LunaTViOS.xcodeproj \
  -scheme LunaTV \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Windows 无法运行 Xcode 或 iOS 模拟器；仓库中的 macOS CI 负责生成未签名 IPA，Windows 上的 AltStore 再使用你的普通 Apple ID 完成个人签名。应用安装后，内容访问支持任意 Wi‑Fi、4G 和 5G，不依赖电脑；但免费签名到期前仍需连接 AltServer 刷新。
