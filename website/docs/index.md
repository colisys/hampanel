---
layout: home

hero:
  name: Hampanel
  text: 服务器运维面板
  tagline: 原生客户端 + 单二进制守护进程，通过双向 TLS 管理你的 Linux 与 Windows 服务器。
  image:
    src: /hampanel-ham.png
    alt: Hampanel 火腿标志
  actions:
    - theme: brand
      text: 快速开始
      link: /guide/
    - theme: alt
      text: 功能一览
      link: /features/
    - theme: alt
      text: 应用商店
      link: /store/

features:
  - icon: 🖥️
    title: 原生客户端，不是网页后台
    details: 桌面与移动端 Flutter 客户端直连受控端，界面响应快，凭据保存在你自己的设备上。一台客户端可保存并切换多台服务器。
  - icon: 🔐
    title: 双向 TLS
    details: 服务端只接受本项目 CA 签发的客户端证书，TLS 最低 1.2、优先 1.3；客户端固定信任该 CA。随机入口前缀作为附加隐藏层。
  - icon: ⚡
    title: 单二进制守护进程
    details: hampaneld 由 Zig 编写，直接调用系统能力，无运行时依赖。systemd 或 Windows 服务托管，装好即可用。
  - icon: 🧰
    title: 从进程到网站
    details: 概览、进程、终端、服务、文件、防火墙、SSH、计划任务、日志放在同一处，日常运维不用在多个工具间切换。
  - icon: 📦
    title: 应用商店
    details: 内置 Compose 应用目录，一键部署 Nginx、PostgreSQL、Gitea、Kafka、vLLM 等 24 个应用；另含软件包与 Nix 入口。
  - icon: 📜
    title: 合规使用
    details: 面板不向任何非法用途提供服务。使用者须遵守所在国家或地区的法律法规，详见使用条款。
---

## 选择安装方式

::: tip 使用 Agent 从源码安装
把下面的提示词交给你使用的编程 Agent，并告知它目标服务器的地址及登录方式。代码块右上角可直接复制。

```text
请从 https://github.com/colisys/hampanel 的 nightly 分支部署 Hampanel。
目标服务器地址：<填写 IP 或域名>；操作系统：<Linux 或 Windows>。
先检查目标机的系统、权限及现有 Hampanel 服务，不要覆盖已有配置或中断其他服务。
阅读仓库 README.md 和对应平台的安装脚本，使用仓库提供的源码安装流程（Linux: deploy/install.sh --mode source --channel nightly --endpoint <目标地址>；Windows: deploy/windows/install.ps1 -Mode source -Channel nightly -Endpoint <目标地址>），不要自行拼装 PKI 或服务文件。
按安装器要求准备 Zig、OpenSSL 等构建依赖，编译并运行必要的检查，再安装并确认 hampaneld 服务正常。
如操作会改变现有服务或网络规则，先列出影响并征得我同意。
最后告诉我客户端安装入口、受控端实际地址、服务状态和 enroll.json 的文件位置；不要在聊天中输出注册凭据或私钥内容。
```

源码安装不会启用每日更新检查。[查看安装细节](/guide/install)。
:::

### Dart：从运维机远程安装

在本仓库根目录运行；需要 Dart、免密 SSH，目标机需要 root 或 sudo 权限。替换示例地址：

```bash
dart run tool/hampanelctl/bin/hampanelctl.dart deploy --channel nightly \
  --host YOUR_SERVER_IP --user root --san YOUR_SERVER_IP --out enroll.json
```

默认下载并校验 nightly 发布二进制；如需从源码构建，加 `--mode source`。[Windows 安装参数](/guide/install#方式二-hampanelctl-远程安装)。

### Shell：在 Linux 目标机安装

在目标服务器上运行，替换示例地址：

```bash
curl -fsSL https://github.com/colisys/hampanel/releases/download/nightly/hampanel-install-linux.sh \
  | sudo bash -s -- --mode binary --channel nightly --endpoint YOUR_SERVER_IP
```

要从源码构建，把 `--mode binary` 改为 `--mode source`。[查看 Windows PowerShell 安装方式](/guide/install#方式三-目标机本地安装)。安装完成后把 `enroll.json` 导入客户端即可连接。
