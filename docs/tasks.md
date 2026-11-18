# 任务核心

持久化在 SQLite `tasks` 表（migration v3）。任务由 daemon 执行，客户端提交后不保持请求连接。

## 状态

`queued → running → succeeded | failed | canceled | interrupted`

- `canceling`：收到取消请求，等待执行器退出。
- `interrupted`：daemon 启动时发现上次遗留的 `running` 任务。
- 终态任务的输出文件保留在 `<data_dir>/tasks/<id>.log`。

## 执行

- 最多 4 个任务并行；排队上限 200。
- 任务执行器由 `tasks.Manager.register(Spec)` 注册；客户端只能提交已注册的 `kind`，不能传任意命令。
- 每个任务有 `lock_key`，同 key 的任务串行（当前调度器读取该字段，下一步在调度时加锁）。
- 输出为单文件 spool，chmod 0600，上限 16 MiB（滚动尾部随 SSE 阶段实现）。
- 幂等键 `(kind, idempotency_key)` 唯一；重复提交返回已有任务。

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

返回 `202 {"task": Summary}`。

`GET /api/v1/tasks?since=<ms>&active=1&limit=100`：只返回摘要，不含输出。

`GET /api/v1/tasks/:id?output_offset=0&output_limit=65536`：详情 + 输出片段；`has_more` 表示还有后续字节。

`POST /api/v1/tasks/:id/cancel`、`DELETE /api/v1/tasks/:id`（仅终态）。

## 恢复与限制

- daemon 重启：`running` → `interrupted`，`canceling` → `canceled`；`queued` 继续执行。
- 输出文件按任务 ID 命名，下载/SSE 阶段增加 `output_base` 与滚动窗口。
- 任务参数以 JSON 落库；含密钥的操作应在 handler 内内存处理，不写入 `params`。
