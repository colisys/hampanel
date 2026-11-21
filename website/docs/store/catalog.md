---
title: 应用目录
description: 应用商店内置的 26 个 Compose 应用与参数说明。
outline: [2, 3]
---

# 应用目录

当前内置 26 个 Compose 应用，按登记的 `category` 分组。参数列的是部署时需要填写的项，留空的密码类参数会自动生成。

## Web

| 应用 | 说明 | 主要参数 |
| --- | --- | --- |
| **Nginx** | 轻量 Web 服务器与反向代理，预置默认站点 | HTTP 端口 |
| **Caddy** | Web 服务器，站点配置与证书存于持久化卷；HTTPS 需配置站点 | HTTP、HTTPS 端口 |

## 数据库

| 应用 | 说明 | 主要参数 |
| --- | --- | --- |
| **PostgreSQL** | 关系型数据库，自动创建用户与数据库 | 端口、用户名、库名、密码 |
| **MariaDB** | MySQL 兼容数据库，初始化库与 root 密码 | 端口、库名、root 密码 |
| **MongoDB** | 文档型数据库，初始化管理员账号并持久化数据 | 服务端口、管理员用户、管理员密码 |
| **Redis** | 内存键值数据库，启用密码保护与持久化 | 端口、访问密码 |

## 存储

| 应用 | 说明 | 主要参数 |
| --- | --- | --- |
| **MinIO** | S3 兼容对象存储，含 API 与控制台 | API 端口、控制台端口、用户、密钥 |

## 消息队列

| 应用 | 说明 | 主要参数 |
| --- | --- | --- |
| **EMQX** | MQTT 消息代理 | MQTT 端口、Dashboard 端口 |
| **Kafka** | 单节点 KRaft 模式；明文连接，适合可信网络 | 客户端可达主机地址、端口 |

EMQX 部署后需在 Dashboard 设置管理员密码并配置客户端认证。Kafka 的 `advertised_host` 要填客户端实际能访问到的主机地址，填 `localhost` 只适合同机访问。

## 开发

| 应用 | 说明 | 主要参数 |
| --- | --- | --- |
| **Gitea** | 自托管 Git 服务，含 Web 与 SSH | Web 端口、SSH 端口 |
| **Hasura GraphQL Engine** | 私有 PostgreSQL 支撑的 GraphQL API，仅本机开放管理端口 | 本机 API 端口、管理员密钥、数据库密码 |
| **Act Runner** | Gitea Actions 运行器 | Gitea 主机、Web 端口、注册令牌 |
| **code-server** | 浏览器中的 VS Code | Web 端口、访问密码 |
| **Nacos** | 单节点服务发现与配置中心，内嵌数据库 | API 端口、gRPC 端口、认证密钥、身份密钥 |

Hasura 使用独立的 PostgreSQL 容器和持久化卷，数据库没有宿主机端口；GraphQL API 与 Console 只绑定 `127.0.0.1:8086`（可修改本机 API 端口），本机访问 `http://127.0.0.1:8086/console`。从远程访问请配置受保护的反向代理，不要直接暴露管理端口。`admin_secret` 用于 Hasura 管理员认证；`db_password` 会原样写入 PostgreSQL 连接 URI，**手动填写时仅使用字母、数字、`-_.~`**，不要包含 `@`、`:`、`/`、`?`、`#`、`%` 等 URI 特殊字符；留空时生成的十六进制密码符合此要求。Compose 文件含明文密钥，须限制读取权限。重新部署时务必复用原数据库密码（以及原管理员密钥）：应用商店留空密码会重新生成，持久化 PostgreSQL 卷不会因此更改已有数据库用户密码，导致 Hasura 无法连接；忘记旧密码时应先手动重置数据库凭据。

Act Runner 会挂载 `/var/run/docker.sock`。容器内因此获得宿主引擎控制权，等同于把宿主机交给该运行器。只在可信的 Gitea 实例上使用。

Nacos 使用内嵌数据库，适合单节点。多节点集群需要改用外部数据库，当前模板未包含。

## 监控与工具

| 应用 | 说明 | 主要参数 |
| --- | --- | --- |
| **Uptime Kuma** | 可用性监控与状态页 | Web 端口 |
| **Adminer** | 单文件数据库管理界面 | Web 端口 |
| **Bark** | 自托管 iOS 推送，只监听本机 HTTP | 本机 HTTP 端口 |
| **Certbot** | Let's Encrypt 签发与续期（standalone） | 域名、邮箱、HTTP 验证端口 |

Bark 不支持 mTLS，对外提供访问需经 WAF 域名路由或自建反向代理。Certbot 的 standalone 模式要求 80 端口空闲。

## AI

| 应用 | 说明 | 主要参数 |
| --- | --- | --- |
| **vLLM** | OpenAI 兼容推理服务 | API 端口、API 密钥 |
| **ComfyUI** | CPU 版图像工作流 | 本机 Web 端口 |
| **NewAPI** | AI 网关，持久化 SQLite | Web 端口、会话密钥 |
| **Sub2API** | AI 网关，附带私有 PostgreSQL 与 Redis | Web 端口、数据库密码、Redis 密码、管理员邮箱与密码、JWT 密钥、TOTP 加密密钥 |

vLLM 需要 NVIDIA GPU、驱动与容器工具包，模板默认加载 `Qwen/Qwen2.5-0.5B-Instruct`。ComfyUI 首次部署从官方源码构建，耗时取决于机器与网络，模型需要自行导入 `models` 卷。

Sub2API 的 TOTP 加密密钥要求 64 位十六进制字符串。

## 游戏

| 应用 | 说明 | 主要参数 |
| --- | --- | --- |
| **MCSManager** | 游戏服务管理面板与守护进程 | 面板端口、守护进程端口 |

部署后需要在 Web 界面添加节点。面板不向容器提供宿主引擎权限。

## 网络

| 应用 | 说明 | 主要参数 |
| --- | --- | --- |
| **FRPS** | frp 服务端 | 控制端口、映射端口、共享令牌 |
| **FRPD (frpc)** | frp 客户端常驻服务 | 服务端地址与端口、本地地址与端口、映射端口、令牌 |
| **EasyTier** | 组网节点 | 网络名称、网络密钥、对等节点主机与端口 |

FRPD 的令牌必须与 FRPS 一致；本地地址要能从容器网络访问到目标服务。EasyTier 使用宿主网络、TUN 设备与 `NET_ADMIN` 能力，会参与宿主机路由，节点的网络配置变化会影响整机连通性。

## 扩展目录

新增应用：在 `daemon/src/store/catalog/` 放一份 Compose 模板，并在 `daemon/src/store/catalog.zig` 登记 slug、名称、描述、分类、图标与参数。

模板用 `{{key}}` 占位，`params` 里每个 `key` 都要在模板中出现；模板里出现的占位符也必须已在 `params` 声明。构建时有测试校验这两点，并检查 slug 唯一、分类非空。