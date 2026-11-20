---
title: 脚本与 Nix
description: 系统工具包管理与 Nix 入口。
outline: [2, 3]
---

# 脚本与 Nix

## 系统工具

在 Linux 上检测可用的包管理器，用来安装常用工具。

支持的包管理器：apt、dnf、yum、zypper、pacman、apk。

- 内置精选工具可直接安装，例如 Git、htop、jq、ripgrep。
- 也可以输入自定义包名安装。
- 可以刷新包索引。

「软件」页另有宿主软件的托管状态与初始化入口，两者关注点不同：商店负责安装，软件页负责接管配置。

## Nix

服务器已安装 Nix 时，商店提供：

- 查看 Nix 状态。
- 对精选目标执行 `nix build` 与 `nix run`。
- 使用受限的自定义 nixpkgs 属性。

属性名经过限制，不接受任意表达式。仓库自带 `flake.nix`，也可以直接使用：

```bash
nix build .#default
nix run .#default -- version
nix develop
```

## 命令与面板的区别

商店里的所有操作都通过受控端 API 执行，不经过客户端的本地 Shell，也不在客户端机器上运行。任务进度、输出和失败原因都在任务页可见。

## 相关

- [应用目录](/store/catalog)
- [软件托管](/features/files#软件托管)