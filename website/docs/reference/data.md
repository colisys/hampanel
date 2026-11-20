---
title: 数据与目录
description: 配置、数据、日志与容器的存放位置。
outline: [2, 3]
---

# 数据与目录

## 受控端

| 内容 | Linux | Windows |
| --- | --- | --- |
| 配置目录 | `/etc/hampanel` | `%ProgramData%\hampanel` |
| 注册凭据 | `/etc/hampanel/enroll.json` | `%ProgramData%\hampanel\enroll.json` |
| 数据目录 | `/var/lib/hampanel` | `%ProgramData%\hampanel` 下对应数据路径 |
| 程序 | `/usr/local/bin/hampaneld` | 服务目录 |
| 服务单元 | systemd `hampanel` | Windows 服务 `hampanel` |
| 更新检查 | `/etc/cron.d/hampanel-update` | 计划任务 `\Hampanel\update` |

### 配置与数据分开

- `config.json` 是安装器写入的引导配置：监听、端口、TLS、入口前缀、更新的通道与镜像，以及 `container` 字段。
- 运行期数据在 `<data-dir>/hampanel.db`（SQLite）。包括运行环境、可编辑配置、审计日志、更新状态与面板设置。

SQLite 使用 vendored amalgamation，不依赖系统 `libsqlite3`。

### 容器引擎的选择

`config.json` 的 `container` 字段记录首次探测结果（`docker` 或 `podman`）。运行时固定使用该值；切换引擎是改这个字段并重启。

## 客户端

| 平台 | 位置 |
| --- | --- |
| Windows | `%APPDATA%\Hampanel` |
| macOS | 应用支持目录 |
| Linux | 用户配置目录 |
| Android / iOS | 应用私有目录 |

客户端保存主机列表、界面设置、AI 会话与模型密钥（桌面端在系统钥匙串，移动端在私有文件）。

## 应用数据

商店部署的应用数据在命名卷中。卷由容器引擎管理，不在上面的目录里。卸载保留数据时卷仍然存在；选择删除数据才会移除。

站点、运行环境、受管 Nginx 容器的配置写在数据目录下，并以相同绝对路径挂载进容器。

## 备份

需要备份的核心是：

1. `<data-dir>/hampanel.db`
2. `config.json`
3. `enroll.json`（用于重新导入客户端，注意含私钥）
4. 需要保留的命名卷与站点目录

历史版本与回收站位于数据目录内，会随数据目录一起备份，但它们不是整机备份方案。