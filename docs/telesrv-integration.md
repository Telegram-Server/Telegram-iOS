# DarkMoon（telesrv）接入方案

本客户端接入自部署的 MTProto 兼容服务端 telesrv（`E:\MyPj\TgSever`，协议扩展在 td fork 的
`_schema/telesrv.tl`）。参照实现：Android（`Telegram-Android` 提交 `69cc9ccf0`、`e3894be5a`、
`9b4ce61f0`）和 Telegram Desktop（`tdesktop` 提交 `18aac3c905`、`2809fa5d95`、`32f2696b62`、
`6ec13169f5` 起的权限系列、`7dd0bfde6f`/`b93c48c0ee`/`c063a78148` 设备绑定）。服务端客户端集成
文档：`TgSever/docs/password-login.md`、`code-login-switch.md`、`sign-up-switch.md`、
`admin-panel-api.en.md`（`set-permissions`、`set-device-limit`）、`apns-push.md`。

## 已定的决策

- 服务器：`167.104.103.22:2398`，单后端，规范 DC 为 2；RSA 公钥与 Android、tdesktop 相同
  （指纹 `0x5d729d647fa6567c`）。
- bundle id `cc.darkmoon`；`api_id`/`api_hash` 保持默认（服务端不校验）；Team ID 和描述文件
  最后再定，开发期用模拟器构建（`build-system/fake-codesigning` + `--disableProvisioningProfiles`）。
- 链接：`darkmoon.cc` 替代 `t.me`，scheme `dm://` 替代 `tg://`；`t.me` 不再当内部链接。
- 登录参照 Android 的流程，界面用 iOS 原生风格；另做已登录后的登录密码管理（Android 没有）。
- 设备绑定要做；员工权限全部入口都要拦，**发送白名单连联系人选择器也过滤**。
- 新文案全部本地化：键加在 `en.lproj/Localizable.strings`（`Telesrv.` 前缀），其他语言由服务端
  `ios` 语言包覆盖。

## 阶段

| 阶段 | 内容 | 状态 |
|---|---|---|
| 0 | 产品身份：`build-system/darkmoon-configuration.json`；`Telegram/BUILD` 里只给官方 bundle id 的能力（associated domains、communication notifications）改为也给 `cc.darkmoon` | 配置文件已加，BUILD 待阶段 2 一起改 |
| 1 | 连接：`TelesrvServer.swift` 常量；DC 1–5 种子同一地址；初始 DC 统一为 2；RSA 公钥；去掉 DoH/CloudKit 备用地址发现；未登录只预取当前 DC 的 key | 已改，待 Mac 验证 |
| 2 | 链接：域名常量；`UrlHandling`/`GenerateTextEntities`/`UrlWhitelist`/`ProxySettings` 解析；入口处 `dm://`→`tg://`；53 个文件的 `t.me` 生成改用常量；scheme 和 Universal Links 注册 | 待做 |
| 3 | TL 和登录：`telesrv.tl` 在构建时拼进 `swift_scheme.tl`；`TelesrvLoginConfiguration`；密码登录、注册；新状态 9/10；AuthorizationUI；隐私与安全里的登录密码管理 | 待做 |
| 4 | 设备绑定：`BuildConfig.m` 生成并存 keychain 共享组的 `device_id`，写进 `initConnection.params`；`AUTHORIZATIONS_TOO_MUCH`/`DEVICE_ID_REQUIRED` 提示 | 待做 |
| 5 | 员工权限：`TelesrvPermissions` 模型；集中判断点、零散入口、操作前拦截和 403 兜底，一个权限一个提交 | 待做 |
| 6 | 本地化：每阶段交付新增的键名和英文原文，供服务端语言包更新 | 随各阶段 |

## 不显而易见的点

- **TL 代码是构建时生成的。** 服务端文档建议 iOS 手写 `ApiTelesrv.swift`，在本仓库行不通：
  TelegramApi 由 Bazel 从 schema 生成并由表驱动引擎序列化。telesrv 方法放在独立的
  `submodules/TelegramApi/telesrv.tl`，由 genrule 和 `generate-swiftpm.sh` 拼接，升级 Layer 时
  只替换 `swift_scheme.tl`。
- **删除、清空、退出聊天是先删本地再发请求，并吞掉服务端错误**
  （`ManagedCloudChatRemoveMessagesOperations.swift`），所以权限必须在操作前拦，403 兜底不够。
- **发送白名单**：`send=false` 时除收藏夹外都不能发，白名单不是例外；`send=true` 且白名单开启时
  私聊只能发给名单内用户（私密聊天按对方用户判断），群和频道不受影响。缺键或 `true` 都算允许。
- **登录 SRP challenge 一次性、5 分钟过期、绑定 auth key**，不落盘，每次提交前重新获取；
  `SRP_ID_INVALID`/`SRP_PASSWORD_CHANGED`/`AUTH_KEY_PERM_EMPTY` 自动重试一次。
- **`UnauthorizedAccountState` 的编码值 4 从未使用**，新状态用 9 和 10。
- **unrestricted-voip 能力只有官方能拿到**，`cc.darkmoon` 下每条 VoIP 推送都必须立即上报 CallKit
  来电，服务端不能用 VoIP 推送发其他内容。推送 topic：`cc.darkmoon` 与 `cc.darkmoon.voip`。
- **设备 ID 必须 App 与所有扩展共用**（它们各自发 `initConnection`），所以存在共享 keychain 组，
  不用 `identifierForVendor`。
- 装过官方版的设备换公钥后要删掉应用重装，否则用 keychain 里缓存的旧 auth key。
