# LunaTV iPhone 免费安装（Windows + 普通 Apple ID）

这条路线不需要付费 Apple Developer Program 账号，也不需要把 Apple ID 或密码交给 LunaTV。应用安装后可通过任意 Wi‑Fi、4G 或 5G 访问内容；电脑只参与首次签名和后续免费签名刷新。

## 一、生成未签名 IPA

1. 将当前仓库放到你自己的 GitHub 仓库中。
2. 打开仓库的 **Actions** 页面。
3. 选择 **Validate iOS client**，点击 **Run workflow**。
4. 等待工作流完成，在页面底部下载 Artifact：`LunaTV-iOS-unsigned`。
5. 解压 Artifact，得到 `LunaTV-iOS-unsigned.ipa`。

未签名 IPA 不能直接在 iPhone 上安装，下一步由 AltStore 用你的普通 Apple ID 签名。

## 二、在 Windows 安装 AltStore

1. 从 Apple 官网安装桌面版 iTunes 和 iCloud；不要使用 Microsoft Store 版本。
2. 安装并运行 AltServer。
3. 用数据线连接 iPhone，解锁并点击“信任此电脑”。
4. 在 iTunes 中启用“通过 Wi-Fi 与此 iPhone 同步”。
5. 在 AltServer 中选择 **Install AltStore**，选择你的 iPhone，并使用普通 Apple ID 登录签名。
6. iPhone 打开“设置 → 通用 → VPN 与设备管理”，信任对应的开发者 App。
7. iOS 16 及以上还需打开“设置 → 隐私与安全性 → 开发者模式”，按提示重启并确认。

建议为侧载单独注册一个 Apple ID。不要把 Apple ID、密码或验证码发给任何人，包括本项目维护者。

## 三、安装 LunaTV IPA

1. 把 `LunaTV-iOS-unsigned.ipa` 放进 iCloud Drive、手机“文件”App，或直接在 iPhone 下载。
2. 打开 AltStore 的 **My Apps**，点击左上角 `+`。
3. 选择 `LunaTV-iOS-unsigned.ipa`，等待签名与安装完成。
4. 首次打开后，在 LunaTV“我的 → 设置”里填写播放源远程配置地址；留空则使用安装包内置配置。

## 四、免费签名刷新

- 普通 Apple ID 的侧载 App 通常 7 天到期，需要在到期前刷新。
- 让 Windows 上的 AltServer 保持运行，iPhone 与电脑连接同一 Wi-Fi，然后在 AltStore 点击 **Refresh All**。
- 免费 Apple ID 同时最多启用 3 个侧载 App；LunaTV 本身占 1 个。
- 若签名已过期，LunaTV 会打不开，但收藏与记录通常仍留在手机中；重新签名安装同一 Bundle ID 后可继续使用。

## 五、版本更新

新版本的操作顺序是：重新运行 GitHub Actions → 下载新版 IPA → 在 AltStore 中选择新版 IPA 安装。LunaTV 内“我的 → 获取 iPhone 新版本”只负责打开你填写的下载页；iOS 不允许未签名 App 自行静默覆盖安装。

内容配置与应用版本是两件事：片库、播放源和直播配置可每 10 分钟静默刷新，不需要重装；只有界面或程序代码升级才需要新版 IPA。
