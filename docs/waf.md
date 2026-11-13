# Hampanel WAF 与 Web 引擎分层设计

## 目标

- Web 引擎可替换：Nginx、Caddy、OpenResty。
- WAF 与引擎解耦：统一由 Caddy + Coraza + OWASP CRS 提供，不依赖引擎自身的脚本能力。
- 同一套 WAF 策略、日志、更新流程对所有引擎生效。
- 不引入 Lua 作为安全边界；OpenResty 仅作为可选引擎。

## 数据流

```
Client
  │  HTTPS (80/443)
  ▼
Caddy edge
  ├─ TLS / HTTP2 / HTTP3
  ├─ Coraza WAF + OWASP CRS
  ├─ 限速 / IP 黑白名单 / 访问控制
  └─ reverse_proxy
        │  127.0.0.1:<engine-port>
        ▼
  Nginx / OpenResty / Caddy
        │
        └─ 站点内容
```

- 引擎不再直接暴露公网端口；只监听回环或内网。
- 若引擎本身是 Caddy，可选择“单 Caddy 进程直接内嵌 Coraza”，避免双层代理。
- 源站必须限制直连，否则 WAF 可被绕过。

## 引擎适配器

站点模型与引擎无关，由适配器渲染：

| 引擎 | 配置形式 | 校验 | 重载 |
| --- | --- | --- | --- |
| Nginx | include 目录中的 vhost | `nginx -t` | systemctl reload nginx |
| OpenResty | 兼容 Nginx vhost | `openresty -t` | systemctl reload openresty |
| Caddy | Caddyfile / JSON 片段 | `caddy validate` | systemctl reload caddy 或 admin API |

- 全局默认引擎 + 每站点可覆盖。
- 引擎切换需要显式确认，并保留旧配置以便回滚。
- 安装与版本信息进入“软件管理”，不假设发行版一定提供 Caddy/OpenResty。

## WAF 边缘

- 组件：Caddy + Coraza Caddy 模块 + OWASP CRS。
- 每个站点独立 WAF 模式：
  - `off`：仅反代。
  - `detect`：记录命中，不阻断（默认）。
  - `enforce`：阻断；切换必须人工确认。
- 可调参数：Paranoia Level、异常阈值、请求体/上传上限、允许方法、
  IP 黑白名单、限速、UA/机器人策略。
- 日志：JSON，包含 request id、站点、规则 ID、异常分、动作；
  默认不记录请求体和敏感头。
- 规则生命周期：
  1. 固定 CRS 版本；
  2. 下载后校验哈希/签名；
  3. staging 配置 + `caddy validate`；
  4. 原子重载；
  5. 失败回滚并保留上一版本；
  6. 面板展示版本、更新时间和回滚入口。
- 自定义规则使用 CRS/SecRule 语法；Caddy CEL/插件只做路由、限速等非 WAF 逻辑。
- 不向用户暴露 Lua，也不把 WAF 规则写在 Nginx/OpenResty 配置里。

## 端口与迁移

- Caddy edge 绑定 80/443。
- 引擎迁移到 `127.0.0.1:<随机/固定端口>`。
- 已有站点切换时：
  - 先停引擎公网监听，改为回环；
  - 生成 edge 反代与 WAF 配置；
  - 校验后启动 edge；
  - 失败回滚到原监听。
- 防火墙与云安全组需要允许 edge 端口，限制引擎端口。

## 交付方式（待定）

1. 应用商店内用 xcaddy 构建带 Coraza 的 Caddy（可复现，但需要 Go 工具链）。
2. 预构建容器镜像（部署简单，但需要维护镜像供应链）。
3. 自带 Caddy 二进制（面板只生成配置和 CRS，最灵活）。

## 分阶段落地

1. 引擎检测、全局引擎设置、软件管理集成。
2. 站点适配器（Nginx/OpenResty 复用现有实现，Caddy 新增）。
3. WAF 边缘：detect 模式、Caddy 配置生成、CRS 安装与校验。
4. enforce 模式、人工审批、规则更新与回滚、日志与审计。
5. 引擎切换迁移与回滚流程。

## 当前实现状态

已落地一个可运行、可验证的 WAF 边缘：

- 构建：WAF 页面通过 `go run github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.7 build --with github.com/corazawaf/coraza-caddy/v2` 生成
  `caddy-waf`，二进制存放在面板数据目录，不污染系统目录。
- 规则：使用 Coraza Caddy 模块的 `load_owasp_crs`，OWASP CRS 内嵌在二进制中，
  无需额外下载规则文件。
- 模式：`off` / `detect` / `enforce`；enforce 切换在 UI 中需要人工确认。
- 配置：监听地址/端口、上游 Web 引擎地址/端口；Caddyfile 先生成再执行
  `caddy validate`，校验失败回滚。
- 运行：面板直接管理 `caddy-waf` 子进程，PID 文件记录状态；支持启动、停止、日志。
- 引擎无关：上游可以是 Nginx、Caddy、OpenResty 或任意 HTTP 服务；源站应只监听回环。
- 实测：构建 v2.11.9；正常请求 200；`UNION SELECT` 在 enforce 下 403、detect 下 200；
  API 安装、配置、启停、日志均通过。

已完成：
- 按站点策略（Host/通配域名、独立上游、inherit/off/detect/enforce）。
- TLS 终止：internal（已实测）与 ACME 配置（已完成 Caddy 校验，需公网 DNS）。
- Coraza 规则 ID 审计：`coraza-audit.log` 可读取，已验证 `942100/942190/942360/949110`。
- Coraza Caddy 固定 v2.6.2，内置 OWASP CRS 4.25.0；重建即更新组件规则。
- TypeSafe risk gateway、GeoIP/GeoSite 选择器、systemd-creds 密钥均已接入。

运维边界：
- 现有引擎公网端口迁移到回环仍需人工规划；WAF 页面负责配置与校验，不自动改写 Nginx/Caddy/OpenResty 站点。
- ACME 需要公网域名与 DNS，本地只验证了 Caddy 配置生成。
- systemd-creds 在非 root 测试环境无法非交互解密；生产 root 环境解密路径已实现。

## Risk gateway 与风险复检（已接入面板）

新增 `waf/risk/main.go`：标准库 Go 反向代理，位于 Caddy WAF 与 Web 引擎之间。

- 对请求体做有界缓冲，调用 TypeSafe `/v1/systemone` 的 `noul` 问题；
  按 `answers.malicious.noul` 与阈值决策。
- 支持 GeoIP CIDR（Geo-Aggregator `source2/<cc>.txt`）和 GeoSite 域名
  （`source1/<tag>.txt`，支持 `full:` / `domain:` / `keyword:`）。
- detect/enforce、fail-open/fail-closed、JSONL 审计日志。
- TypeSafe 密钥使用 systemd-creds 加密文件，启动时解密到内存；不写入配置/日志/API。
- 已用 mock `/v1/systemone` 验证：正常 POST 200、风险 POST 403（enforce）、
  detect 200、GeoSite deny 403，日志包含概率与原因。
- 面板侧已接入：
  - WAF 安装会同时构建 Caddy + `hampanel-risk`；启动时先启动 risk gateway，再启动 Caddy。
  - Caddy 上游指向 risk gateway，risk gateway 上游指向 Web 引擎；保留原始 Host。
  - WAF 页面支持 TypeSafe 配置、密钥加密保存、Geo 选择器、risk 日志。
  - Geo 数据来自 Geo-Aggregator；保存配置时下载所选 CIDR/域名列表并重启 WAF。
  - 已验证：normal POST 200、TypeSafe high-risk POST 403、GeoSite deny 403、GeoIP CIDR deny 403。
  - TypeSafe API Key 使用 systemd-creds 保存；非 root 测试环境无法非交互解密，gateway 会继续启动但不带 key；生产 root 环境可正常解密。
