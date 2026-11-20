---
title: 安装客户端
description: Linux、Windows、macOS、Android、iOS 客户端的获取与运行。
outline: [2, 3]
---

# 安装客户端

客户端是 Flutter 应用，覆盖桌面与移动端。客户端只负责展示与操作，实际执行在受控端。

## 下载

从 [GitHub Releases](https://github.com/colisys/hampanel/releases) 获取。滚动预发布在 [`nightly`](https://github.com/colisys/hampanel/releases/tag/nightly) 标签下。

| 平台 | 产物 | 说明 |
| --- | --- | --- |
| Linux | `hampanel-client-linux-x86_64.AppImage` | 单文件，`chmod +x` 后运行 |
| Windows | `hampanel-client-windows-x86_64.exe` | 单文件绿色版，双击运行 |
| macOS | `hampanel-client-macos-<arch>.dmg` | 需 macOS 13+ |
| Android | `hampanel-client-android-universal.apk` | 通用包 |
| iOS | `hampanel-client-ios-unsigned.ipa` | 未签名，需自行签名后安装 |

## Linux

```bash
chmod +x hampanel-client-linux-x86_64.AppImage
./hampanel-client-linux-x86_64.AppImage
```

AppImage 依赖系统自带的 GTK3 运行库，主流桌面发行版都已提供。若系统缺少 FUSE：

```bash
./hampanel-client-linux-x86_64.AppImage --appimage-extract-and-run
```

## Windows

双击 `hampanel-client-windows-x86_64.exe`。程序首次运行会解压到用户临时目录，凭据与设置保存在 `%APPDATA%\Hampanel`，不写入安装目录。

## macOS

打开 DMG 并拖入「应用程序」。首次启动若被系统拦截，右键选择「打开」。客户端会按 Metal 能力自动选择 Impeller 或 Skia 渲染。

macOS 客户端只能管理 Linux 与 Windows 服务器。

## Android

安装 APK 即可。移动端为管理端：没有桌面本机隧道功能，但可以完成其余日常操作。

如安装包名带 `-unsigned`，说明构建时未提供签名密钥，需要自行签名。

## iOS

IPA 未签名，需要用你自己的证书与描述文件重新签名后侧载。

## 本地运行与构建

```bash
cd app
flutter pub get
flutter run -d linux      # 或 -d windows、-d macos
flutter run -d android    # 或 -d ios
```

发布构建示例：

```bash
cd app
flutter build linux --release \
  --dart-define=HAMPANEL_VERSION=0.1.0 \
  --dart-define=HAMPANEL_COMMIT=$(git rev-parse --short HEAD)
```

## 接下来

首次启动后需要导入凭据：[完成首次连接](/guide/first-connect)。