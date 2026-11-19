# AI 助手

AI 助手运行在 Flutter 管理端，daemon 不保存模型配置或密钥。

## 配置与密钥

- Base URL、模型、协议保存在管理端 `ai_config.json`（权限 0600）。
- API Key 通过系统钥匙串保存：
  - Linux：`secret-tool`（libsecret-tools；需要解锁的桌面钥匙环）
  - macOS：`security` / Keychain
  - Windows：Credential Manager（PowerShell PasswordVault）
- 如果钥匙串不可用，AI 页面会提示安装/解锁，不会退化为明文保存。
- 「系统设置 → AI 工具权限」可勾选允许 AI 使用的工具；未勾选的工具不会出现在模型工具列表中，
  即使模型请求也会被拒绝。
- 「系统设置 → AI 敏感文件路径」维护路径前缀列表。命中列表或其子路径的 `read_file`
  必须人工批准；其他文件读取自动执行。默认包含 `/etc/shadow`、`/etc/ssh`、`/root/.ssh`、
  `/etc/ssl/private` 等。

支持两种 OpenAI 兼容协议：

- `chat_completions`：`POST {base}/chat/completions`，默认使用流式（`stream: true`）逐段
  渲染文本，结束时再执行工具调用循环。
- `responses`：`POST {base}/responses`（包含 `function_call` / `function_call_output`）

## 对话与渲染

- 左侧「对话」列表保存多条会话，可新建、切换、删除；窄屏下改由标题栏按钮打开底部弹层。
- 会话与消息持久化在管理端本地配置文件，随应用重启保留。
- 回复使用内置 Markdown 渲染：标题、无序/有序列表、引用、分隔线、代码块、
  行内粗体/斜体/代码，以及**表格**（支持左/中/右对齐与横向滚动）。

## 工具白名单与审批

AI 只能调用客户端注册的白名单工具，**不存在 shell/脚本工具**。工具覆盖：
系统信息、指标、进程、文件读取、回收站、服务、容器、站点、防火墙、计划任务、
SSH 状态、Fail2ban 状态、日志读取，以及少量修改类操作（写文件、服务/容器操作、
防火墙规则、Nginx 重载、Fail2ban 封禁/解封）。

日志工具（`list_log_sources`、`read_logs`、`read_service_logs`、
`read_container_logs`）默认关闭，并在设置中归入高风险组：日志可能包含令牌、
IP、请求体等敏感信息。即使勾选，每次读取也会先把命中的日志行复制到编辑器，
由用户检查、删改后再发送给助手；编辑器里最终的内容就是助手收到的全部内容，
取消则不会读取。
`add_cron_job` 同样默认关闭，必须在系统设置中显式勾选；它只能创建计划任务，
不能直接执行 shell，且每次创建仍需人工批准。

- 普通只读工具自动执行；`read_file` 命中敏感路径时需要人工批准。
- 写文件（`write_file`）会先创建历史版本；若目标文件已存在，daemon 的读取循环
  按 EOF 语义处理（不把正常结束当成错误）。
- **所有修改类工具**执行前弹出人工审核对话框，展示操作摘要与完整参数；
  用户拒绝时结果会返回给模型，且不会重试。
- 文件删除只能调用 `delete_path` → daemon 文件删除接口 → 回收站，无法永久删除。
- 文件写入会触发行级历史版本。

系统提示词明确要求：禁止请求 shell，删除只能进回收站，修改操作需用户批准。
工具勾选与敏感路径保存在管理端 `ai_config.json`（`enabled_tools` / `sensitive_paths`）。
