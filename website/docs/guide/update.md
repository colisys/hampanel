---
title: 升级与更新
description: 客户端与受控端各自的更新方式和通道选择。
outline: [2, 3]
---

# 升级与更新

客户端与受控端分开发布、各自更新，互不影响。

## 受控端

二进制安装在安装时设置每日更新检查：

- Linux：`/etc/cron.d/hampanel-update`
- Windows：计划任务 `\Hampanel\update`

在 **设置 → 常规 → 更新** 查看当前通道和版本，按顺序点击 **检查更新**、确认发布版本、**立即更新**；提交后到 **任务** 查看输出，待服务重启再测试连接。需要换通道或 GitHub 镜像时，先保存设置再检查。

源码安装需重新执行源码构建与安装流程升级；其更新检查任务默认关闭。

## 客户端

在 **设置 → 常规 → 管理端更新** 选择 `stable` / `nightly` 并保存，然后点击 **检查更新**、**下载客户端**。下载完成后关闭旧客户端，安装新版本并重新打开。未连接主机时，也可以从启动页进入管理端更新。

## 通道

| 通道 | 对应 | 行为 |
| --- | --- | --- |
| `stable` | 正式 tag | 只在有正式 Release 时可用 |
| `nightly` | nightly 分支 | 滚动预发布，更新频率高 |

通道分别保存在受控端和当前客户端，修改其中一处后另一处仍使用原通道。

## 镜像

访问 GitHub 受限时，在本地安装脚本使用 `--github-mirror <url>`（Windows：`-GithubMirror <url>`），或分别在受控端与客户端的更新设置中填写镜像地址。保存后重新检查更新。

## 手动升级

```bash
# Linux：重新执行安装器即可覆盖安装
curl -fsSL https://github.com/colisys/hampanel/releases/download/nightly/hampanel-install-linux.sh \
  | sudo bash -s -- --mode binary --channel nightly --endpoint [IP]
```

升级会保留 `/etc/hampanel` 下的配置与证书，以及 `/var/lib/hampanel` 下的数据。