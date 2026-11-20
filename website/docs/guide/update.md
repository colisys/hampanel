---
title: 升级与更新
description: 客户端与受控端各自的更新方式和通道选择。
outline: [2, 3]
---

# 升级与更新

客户端与受控端分开发布、各自更新，互不影响。

## 受控端

二进制安装会在安装时写入每日更新检查：

- Linux：`/etc/cron.d/hampanel-update`
- Windows：计划任务 `\Hampanel\update`

在「设置 → 常规 → 更新」中还可以手动检查、立即更新、切换通道、配置 GitHub 镜像。

源码安装不写入更新检查，面板 API 也会拒绝再添加此类计划任务。如需升级，重新执行构建与安装流程。

## 客户端

「设置 → 常规 → 管理端更新」可选择 `stable` / `nightly` 通道，检查新版本并跳转到对应平台的安装包。未连接任何主机时，启动页也能检查更新。

## 通道

| 通道 | 对应 | 行为 |
| --- | --- | --- |
| `stable` | 正式 tag | 只在有正式 Release 时可用 |
| `nightly` | nightly 分支 | 滚动预发布，更新频率高 |

通道不会自动切换。安装时选哪个，后续就按哪个检查。

## 镜像

如访问 GitHub 不便，可在安装时加 `--github-mirror <url>`，或在设置中长期修改。Release 查询与下载都会经该前缀拼接。

## 手动升级

```bash
# Linux：重新执行安装器即可覆盖安装
curl -fsSL https://github.com/colisys/hampanel/releases/download/nightly/hampanel-install-linux.sh \
  | sudo bash -s -- --mode binary --channel nightly --endpoint [IP]
```

升级会保留 `/etc/hampanel` 下的配置与证书，以及 `/var/lib/hampanel` 下的数据。