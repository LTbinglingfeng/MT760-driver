# MT760 Control

**简体中文** | [English](README.en.md)

**雷柏（Rapoo）MT760 鼠标的第三方 macOS 驱动 / 设置工具。**

这是一个原生 macOS App（Swift + SwiftUI），用来管理 MT760 鼠标的参数：DPI、当前 DPI 档位、回报率和按键映射。不需要安装官方的 A HUB Office。

> 本项目是独立开发的互操作工具，与 Rapoo（雷柏）没有任何隶属或授权关系，也不包含任何官方二进制、固件或源码。

## 为什么要做这个

Rapoo 官方驱动（A HUB Office）的 macOS 版问题非常多，而且长期没人修复。本项目参照官方驱动的通信协议，在 macOS 上重新实现了 MT760 的常用设置功能，作为它的替代品：

- 原生 Apple Silicon（arm64）程序，不依赖 Rosetta；
- 体积小，无第三方依赖，不安装后台服务、内核扩展或启动项；
- 只做鼠标参数设置，不联网、不登录账号、不收集数据。

## 功能

| 功能 | 说明 |
|---|---|
| DPI | 查看 7 个档位的 DPI 数值，修改当前档位的 DPI（50–4000，步进 50） |
| 当前档位 | 点击档位卡片即可切换当前 DPI 档位 |
| 回报率 | 125 / 250 / 500 / 1000 Hz |
| 按键映射 | 为每个按键设置功能：鼠标按键、DPI 切换、狙击、连发、滚轮方向、多媒体键、常用快捷键、“修饰键 + 按键”组合键、禁用、恢复默认等 |
| 设备信息 | HID 接口与描述符详情、原始配置字节、操作记录、导出诊断 JSON |

插上鼠标后 App 会自动读取当前配置；修改即时写入，然后读回校验。设置保存在鼠标里，拔插或断电后仍然保留；之后换到没有安装本工具的电脑上也照样生效。

**暂不支持：** 宏、灯效、配置文件（Profile）切换、配对、固件升级、恢复出厂设置。

## 兼容性

- **鼠标**：Rapoo MT760（普通版），USB 有线连接（`24AE:4500`）。已在固件 V0.1.4.4 上实测可用。其他固件版本、无线接收器、蓝牙连接，以及 MT760 的其他变体都没有验证过。
- **系统**：macOS 13 及以上。
- **架构**：发布包仅支持 Apple Silicon（arm64），不提供 Intel 兼容支持。
- **语言**：界面支持简体中文和英文。点工具栏的地球图标（或菜单栏“显示 → 语言”）即可即时切换，选择会被记住；默认“跟随系统”（首选中文时显示中文，否则显示英文）。

## 安装

可以从本仓库的 **Releases** 下载 `macos_arm64` ZIP（仅支持 Apple Silicon）。解压后将 `MT760 Control.app` 拖入“应用程序”；压缩包也包含 `mt760-diagnostics` 和双语 README。发布包使用 ad-hoc 签名，未经 Apple 公证，首次打开可能被 Gatekeeper 拦截。确认下载来源后，按 macOS 提示在“系统设置 → 隐私与安全性”中允许打开；升级后可能需要重新授予输入监控权限。

也可以从源码构建。只需要 Xcode Command Line Tools（Swift 6 工具链），不需要完整的 Xcode，也不需要 Homebrew 或管理员权限。

```bash
xcode-select --install            # 如尚未安装 Command Line Tools
git clone <本仓库地址>
cd MT760-driver
./scripts/build-app.sh
open "dist/MT760 Control.app"
```

构建完成后，可以把 `dist/MT760 Control.app` 拖进“应用程序”文件夹。

签名说明：`build-app.sh` 默认使用钥匙串里第一个 “Apple Development” 证书签名，没有证书时退回 ad-hoc 签名。可以用环境变量 `CODE_SIGN_IDENTITY` 指定其他身份。构建产物不做公证（notarization）。

## 首次使用：输入监控权限

MT760 的配置接口在 macOS 上会被识别为“键盘”类 HID 设备，所以 macOS 要求 App 先获得 **“输入监控”** 权限才能打开它。（本 App 并不监听任何键盘或鼠标输入。）

1. 第一次启动时，App 会自动弹出系统授权提示；
2. 在“系统设置 → 隐私与安全性 → 输入监控”中打开 **MT760 Control**；
3. 按 App 里的提示重新打开 App。

授权按签名身份匹配：

- 用 Apple Development 证书签名时，重新构建后授权依然有效；
- 用 ad-hoc 签名时，每次重新构建都需要重新授权。

授权失效时可以先重置，再重新授权：

```bash
tccutil reset ListenEvent local.mt760.control
```

## 使用

- **自动读取**：插上鼠标后自动读取 DPI、回报率和按键配置。按 `⌘R` 或切回 App 窗口（距上次读取超过 5 秒）时会重新读取。
- **DPI**：点击档位卡片切换当前档位；用滑块、输入框或步进器调整当前档位的 DPI 数值，点“应用”或按回车写入。
- **回报率**：直接点选目标回报率。
- **按键**：在按键右侧的菜单里选择新功能即写入。“自定义组合键…”可以设置一个修饰键加一个按键。不合规的选项会显示为不可选，例如去掉最后一个左键。
- **诊断导出**：`⌘E`，或“设备信息 → 导出诊断…”。

> 请先退出官方 A HUB Office 再使用本工具，两者不能同时访问设备。官方程序运行时，本工具会拒绝操作并给出提示。

## 工作方式与安全设计

为了尽量不让鼠标进入异常状态，每次修改都按固定流程执行：

1. **现场读取**：先读出设备当前数据，并和界面上显示的数据逐字节比对。不一致（比如期间按了鼠标上的 DPI 键）就放弃写入，并重新读取。
2. **写入一次**：只发送一条官方协议中对应的写命令，只改动目标字节，其余字节原样保留。
3. **读回校验**：重新读出数据，确认只有预期的字节发生了变化。

在此基础上：

- 失败时**不重试、不回滚**，App 会自动重新读取，显示设备的真实状态；
- 所有设备访问都在一个独立的 helper 进程（`mt760-read-helper`）里进行，有超时限制，同一时间只运行一个；
- 每 2 秒一次的设备扫描只做枚举，不打开设备；
- 不修改系统设置，也不修改官方 App；不发起任何网络请求；
- 导出的诊断文件不含序列号、蓝牙地址或输入事件，但包含产品信息、描述符和原始通信字节，分享前请自行检查。

协议细节（内存地址、命令格式、按键编码）见 [`Sources/MT760Core/`](Sources/MT760Core/) 中各文件的注释。

## 诊断命令行工具

`mt760-diagnostics` 只枚举 Rapoo（VID `24AE`）HID 接口，不会打开设备，也不会和设备通信：

```bash
./dist/mt760-diagnostics --json > diagnostics.json
hidutil list --matching '{"VendorID":9390}'
```

遇到问题提交 issue 时，请附上诊断 JSON 和 App 里导出的操作记录。

## 已知限制

- 只支持 USB 有线连接下的普通 MT760。
- 只能修改**当前**档位的 DPI 数值，不能增删档位。
- 切换档位时会照搬官方程序的字节顺序，辅助区两个含义未知的字节会被交换（与官方行为一致），操作记录里会列出这一变化。

## 开发

```text
Sources/MT760Core/        HID 枚举、描述符解析、协议编解码、写入计划与校验、helper 监督、IOKit 读写事务、本地化（Localization.swift）
Sources/MT760App/         SwiftUI 界面（AppModel 设备队列，每个页面一个视图文件）
Sources/MT760ReadHelper/  独立的设备访问进程
Sources/MT760Diagnostics/ 只做枚举的命令行工具
Tests/                    离线测试（不访问 HID 硬件）
Resources/                Info.plist 与 App 图标
scripts/                  构建、测试、图标生成脚本
```

```bash
swift build                     # Debug 构建
./scripts/test.sh               # 离线测试（Swift Testing，需要 macOS 14+）
MT760_LANG=en ./scripts/test.sh # 以英文文案运行测试
./scripts/build-app.sh          # Release 构建并打包为 .app
codesign --verify --deep --strict "dist/MT760 Control.app"
swift scripts/make-icon.swift   # 重新生成 Resources/AppIcon.icns
```

`scripts/test.sh` 会自动定位 Command Line Tools 中 Swift Testing 的宏插件，不需要修改系统配置。

界面与错误文案以 `L("中文", "English")` 成对书写（见 `Sources/MT760Core/Localization.swift`），新增或修改文案时请同时提供两种语言。界面里的语言选择保存在 App 自己的偏好设置中；选“跟随系统”时，可以用环境变量 `MT760_LANG=zh|en` 覆盖系统语言（测试时常用）。

欢迎提交 issue 和 PR。如果你有其他固件版本或无线版本的 MT760，欢迎反馈诊断结果。

## 免责声明

本工具通过向鼠标发送配置命令来工作，命令格式来自对官方程序的分析。作者已尽量限制写入范围并做了逐字节校验，但仍不能保证在所有设备和固件上都安全。使用风险由使用者自行承担。

“Rapoo”“雷柏”和“MT760”是其各自所有者的商标。本项目与 Rapoo 没有任何关联。
