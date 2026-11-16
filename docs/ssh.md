# SSH 管理

面板「SSH」页面使用二级导航：**概览**（状态与生效配置）、**密钥**（authorized_keys）、
**日志**（记录方式与日志查看）。窗口宽度小于 720px 时二级导航收进标题栏的紧凑菜单。

## 状态

`GET /api/v1/ssh` 返回 sshd 版本、systemd 单元、运行状态、是否使用 drop-in，
以及 `sshd -T` 解析出的 `port`、`PermitRootLogin`、`PasswordAuthentication`、
`PubkeyAuthentication`。非 root 运行时 `sshd -T` 可能失败，此时 `message`
会提示以 root 运行；公钥管理仍按用户读取 `~/.ssh/authorized_keys`。

## 配置写入

1. 优先使用 `/etc/ssh/sshd_config.d/99-hampanel.conf`。
2. 若主配置尚未包含 `Include /etc/ssh/sshd_config.d/*.conf`，会在文件顶部插入
   带标记的 Include 块，并备份为 `sshd_config.hampanel.bak`。
3. 写入后执行 `sshd -t -f /etc/ssh/sshd_config`。
4. 校验失败立即恢复主配置与 drop-in；成功后 `systemctl reload sshd|ssh`。
5. 修改端口不会自动改防火墙；响应会明确提示检查放行规则。

面板不会覆盖主配置中的其他指令，所有写入都经过参数校验。生产环境建议保留一个
已登录的 SSH 会话，再修改端口或认证方式。

## 公钥

- `GET /api/v1/ssh/keys?user=root`
- `POST /api/v1/ssh/keys` `{ "user": "root", "key": "ssh-ed25519 AAAA...", "comment": "" }`
- `POST /api/v1/ssh/keys/delete` `{ "user": "root", "index": 0 }`

仅接受 OpenSSH 公钥类型；拒绝控制字符、超长内容与非法 Base64。写入时自动创建
`~/.ssh`（0700）、`authorized_keys`（0600），并设置属主。重复公钥会直接返回“已存在”。

## 安全提示

- 建议先确认密钥登录可用，再关闭密码登录。
- 所有配置修改都有回滚，但错误的防火墙/云安全组设置仍可能导致失联。
- 公钥管理等价于授予登录权限，只应对可信客户端开放本面板（mTLS 已强制）。

## 日志记录与查询

`GET /api/v1/ssh/logging` 返回当前模式：

- `syslog`：sshd 日志进入 journald / auth.log（系统默认）。
- `file`：通过 rsyslog 额外写入 `/var/log/hampanel-sshd.log`。
  syslog 管线保留，因此 fail2ban 仍能正常读取日志。

`POST /api/v1/ssh/logging` `{ "mode": "syslog" | "file" }` 切换模式：

- 文件模式要求系统存在 rsyslog（可从「应用商店 → 系统工具」安装）。
- 写入 `/etc/rsyslog.d/49-hampanel-sshd.conf`，执行 `rsyslogd -N1` 校验并重载 rsyslog。
- 失败自动恢复原配置；无需重启 sshd，不会中断 SSH 连接。

`GET /api/v1/ssh/logs?source=journal|auth|file&lines=200` 查询日志：

- `journal`：`journalctl -u sshd|ssh`
- `auth`：`/var/log/auth.log` 或 `/var/log/secure`
- `file`：`/var/log/hampanel-sshd.log`

来源为 `auto` 时按当前模式选择。UI 的「SSH」页面提供记录方式切换（带确认）、
来源选择、行数截断（200/300/1000/2000 行）与日志查看；日志行首的 journald
时间戳在展示前统一转换为本机时区。
