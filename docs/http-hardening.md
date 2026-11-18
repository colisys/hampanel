# HTTP 栈加固

适用于 `daemon/src/http/*`、`server.zig`、`net/conn.zig`、`tls.zig`。认证模型是 mTLS 单管理员 API；不可信输入包括请求行、头、体、路径/查询、任务参数、任务输出与下载文件名。

## 已实施

- 套接字读写超时：TLS 握手/请求读取 30s，响应写入 60s；慢连接不再长期占用线程。
- 请求行与头：
  - 仅接受 `HTTP/1.0`/`HTTP/1.1`；`HTTP/1.1` 必须带非空 `Host`。
  - header name 按 token 校验；header value 拒绝 CR/LF、NUL 与控制字符。
  - 拒绝重复 `Content-Length`；`Content-Length` 仅允许十进制数字；`Transfer-Encoding` 一律拒绝。
  - target 长度上限 8 KiB，拒绝控制字符与 absolute-form URL。
- 路由路径：入口 prefix 剥离后拒绝 `..`、`.`、反斜杠、NUL 与百分号编码；不做编码解码。
- 入口 prefix：恒定时间比较。
- 响应：
  - 所有动态响应头（含 `extra`）校验 name/value，拒绝 CR/LF 注入。
  - `Content-Disposition` 使用 ASCII 回退名 + RFC 6266 `filename*`；原文件名做百分号编码。
  - `HEAD` 返回与 GET 一致的 `Content-Length`，不发送 body。
- 连接：单连接最多 1000 个请求；套接字超时覆盖 keep-alive 空闲。
- TLS：最低 TLS 1.2，关闭压缩、重协商、会话票据；校验客户端证书链（depth 4）。
- WebSocket：校验 `Sec-WebSocket-Version: 13`、key 解码为 16 字节；客户端帧必须掩码；控制帧必须 FIN 且 ≤125 字节；拒绝 64 位长度最高位。

## 随任务/SSE 实施

- SSE chunked 编码、写超时、15s 心跳、连接最长 30 分钟。
- SSE 订阅总上限与每任务上限；有界事件队列与慢客户端断开。
- 任务/SSE 路由的输入校验与输出偏移 clamp。
- per-CN 连接/认证失败限速。
- 请求解析器 fuzz 目标与畸形请求语料。

## 验证

单元测试：`daemon/src/http/validate.zig`（header/target/CL/路径/恒定时间/Content-Disposition）、`http/response.zig`（CR/LF 拒绝）、`util/prefix.zig`。

手工回归（本地 mTLS 实例）：

- 正常 health 请求。
- 重复 `Content-Length` → 400。
- 缺失 `Host` → 400。
- `/secret/../api/v1/health` → 400。
- `HEAD /secret/api/v1/health` → 仅响应头。
