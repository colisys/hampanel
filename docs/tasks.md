# 任务核心

长操作不再占用客户端的 HTTP 请求。客户端提交任务后立即拿到任务 ID，结果通过 SSE 或轮询获取。任务持久化在 SQLite `tasks` 表（migration v3），daemon 重启后继续执行 `queued` 任务。

## 状态

`queued → running → succeeded | failed | canceled | interrupted`

- `canceling`：已收到取消请求，等待执行器退出。
- `interrupted`：daemon 启动时发现上次遗留的 `running` / `canceling` 任务。
- 终态任务的输出保留在 `<data_dir>/tasks/<id>.log`，文件权限 0600。

## 执行

- 最多 4 个任务并行，排队上限 200。
- 任务执行器由 `tasks.Manager.register(Spec)` 注册；客户端只能提交已注册的 `kind`。
- `lock_key` 相同的任务串行，避免同一资源被并发修改。
- 幂等键 `(kind, idempotency_key)` 唯一，重复提交返回已有任务。
- 输出 spool 上限 16 MiB；写满后丢弃最旧的一半并推进 `output_base`，长构建始终保留最新输出。

### 已注册的 kind

| kind | 说明 | lock_key |
| --- | --- | --- |
| `nix.build` | `nix build` 白名单属性 | `nix` |
| `nix.run` | `nix run` 白名单属性 | `nix` |
| `package.install` | 安装白名单工具（含 Nix） | `packages` |
| `package.custom` | 安装自定义包名 | `packages` |
| `package.refresh` | 刷新软件源索引 | `packages` |
| `waf.install` | 通过 xcaddy 构建 Coraza Caddy | `waf` |
| `waf.start` / `waf.stop` | WAF 进程启停 | `waf` |
| `runtime.create` | 创建运行时环境 | `runtime` |
| `runtime.rebuild` | 重建环境镜像 | `runtime` |
| `runtime.extensions` | 保存扩展并重建 | `runtime` |
| `runtime.action` | start / stop / restart / remove | `runtime` |
| `store.deploy` | 渲染参数并 `compose up -d` | `store` |
| `software.initialize` | 初始化软件（fail2ban / ClamAV / Supervisor / Pure-FTPd） | `software` |
| `store.app` | 应用商店实例 start / stop / remove | `store` |
| `service.action` | systemd 单元 start / stop / restart / reload / enable / disable | `services` |
| `sites.reload` | 校验并重载 Nginx / Caddy | `sites` |
| `host.change` | swap / swap-device / ntp / grub | `host` |
| `update.apply` | 下载、校验、替换二进制并安排重启 | `update` |

Docker 镜像与 compose 的 `up` / `pull` 仍走 `/docker/jobs` 的任务接口，不重复纳入任务核心。
`/etc/hosts`、站点保存、服务配置、Docker compose 的 `down` / `restart`、更新检查属于秒级操作，保持同步。

## API

`POST /api/v1/tasks`

```json
{
  "kind": "nix.build",
  "title": "nixpkgs#hello",
  "params": {"target": "hello"},
  "idempotency_key": "客户端生成的随机串"
}
```

返回 `202 {"task": Summary}`。未注册的 `kind` 返回 400，队列满返回 429。

`GET /api/v1/tasks?since=<ms>&active=1&limit=100`：摘要，不含输出。

`GET /api/v1/tasks/:id?output_offset=0&output_limit=65536`：详情 + 输出片段。`output_base` 是 spool 已丢弃的字节数，`has_more` 表示还有后续字节。

`POST /api/v1/tasks/:id/cancel`：请求取消（幂等）。

`DELETE /api/v1/tasks/:id`：删除终态任务及其输出文件；运行中返回 409。

## SSE

- `GET /api/v1/tasks/events`：每秒推送 `snapshot`，15s 心跳，单连接最长 30 分钟。
- `GET /api/v1/tasks/:id/events?output_offset=N`：推送 `status` 与 base64 编码的 `output` 增量，终态后关闭。spool 回卷时推送 `reset`，客户端清空已累积输出并从 0 重读。
- chunked 响应；写失败即断开，不阻塞任务执行。

## 限制

| 限制 | 值 |
| --- | --- |
| 单连接最长 | 30 分钟 |
| 全部并发流 | 32 |
| 每个客户端证书并发流 | 4 |
| 每个客户端证书提交 | 30 次 / 分钟 |
| 终态任务保留 | 7 天 |
| 终态任务条数 | 最多 500 |

超出限制返回 429 / 503，客户端按退避重连。

## 恢复与清理

- daemon 重启：`running` → `interrupted`，`canceling` → `canceled`；`queued` 继续执行。
- 调度器每 5 分钟清理：超过 7 天与超出 500 条的旧终态任务，同时删除其输出文件。
- 任务参数以 JSON 落库；含密钥的操作在 handler 内内存处理，不写入 `params`。
