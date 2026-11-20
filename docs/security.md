# 安全模型

Hampanel 管理端与受控端之间是双向 TLS（mTLS）：客户端校验服务端证书，服务端也校验
客户端证书。注册凭据（enroll.json）里包含 CA 证书、客户端证书与私钥。

## 信任链

1. 客户端只信任注册凭据中的 CA；服务端证书必须由该 CA 签发，并且主机名匹配
   `endpoint`。
2. 每个客户端有独立的客户端证书，服务端按 CN 记录并审计请求。
3. 证书私钥只保存在本机：桌面端 `hosts.db` 为 0600，Android/iOS 位于应用私有沙箱。
4. 桌面端 AI API Key 使用系统钥匙串；移动端使用应用私有文件。

## 指纹核对

仅校验“链能串到某个 CA”不够，因为注册凭据本身可能被替换。导入凭据时客户端会展示：

- Endpoint
- 客户端 CN
- CA SHA-256
- 服务端证书 SHA-256

必须通过带外渠道核对后才能继续。服务端可用 `hampaneld show --config ...` 或
安装时的输出查看同样的指纹。

## 会话前身份复核

`/api/v1/health` 会返回服务端实际加载的 CA 与服务端证书指纹。客户端在建立会话前
比对注册凭据中的指纹；不一致时直接阻止进入面板，并提示重新导入凭据。TLS 链校验
与之互补：链校验防伪造签名，指纹比对还能发现证书轮换或凭据被替换。

## 本机固定（TOFU）

首次导入时，CA 与服务端指纹会写入本机 `hosts.db`。之后如果数据库中的注册凭据被
修改，指纹与固定值不一致，客户端会要求重新核对后才继续。更新指纹必须由操作者
显式确认，不能自动接受。

## 轮换证书

服务端轮换证书后，旧注册凭据会停止工作：

1. 在服务端执行 `hampaneld show` 获取新指纹（或重新 `hampaneld init` 并保留数据目录）。
2. 在客户端重新导入新的 `enroll.json`。
3. 通过带外渠道核对新指纹并确认。

## 边界

- 指纹核对是 TOFU（首次使用即信任）；它防替换、防静默轮换，但不防首次导入时的
  主动中间人。首次凭据应通过可信渠道传递。
- 没有硬件密钥或口令加密的私钥保护；桌面端依赖文件权限，移动端依赖应用沙箱。
- 客户端不实现证书固定到具体公钥（SPKI）；当前固定的是 CA 与服务端证书指纹。

## 安全中心

安全中心聚合 SSH、WAF、防火墙、Fail2ban，并提供扫描感知、主机探测、蜜罐、
文件防篡改与 SELinux 入口。能力检测如实上报：`/api/v1/security/capabilities`
返回 eBPF、chattr、qemu、nft、ufw、SELinux 与是否 root，入口按结果禁用而不是
点了才报错。

## 扫描感知

被动采集主机收到的半开连接（SYN），把"一个来源在窗口内触达了多少个不同端口"
作为扫描信号，超阈值即拉黑。

- 探针是 `bpftrace` 脚本（`<data>/security/scan-sensor.bt`），挂在
  `tcp_v4_rcv` / `tcp_v6_rcv` 上，按 `(来源, 端口)` 聚合，每 5 秒输出一行 JSON。
  选 bpftrace 而不是编译 libbpf 对象，是因为后者要求构建机内核头与运行内核一致。
- 来源地址与端口在内核结构里都是网络序，按整数读出后 IPv6 的每个 16 位组与端口
  都需要字节交换；两处都按真实探针输出校准过，不是推测。
- 默认阈值：单来源 12 个不同端口。命中后写入
  `<data>/security/scan-banned.txt` 并在 ufw 中添加拒绝规则。IPv4 用
  `ufw insert 1`，让新规则优先于既有放行；`ufw insert` 对 IPv6 会报
  “无效位置”，因此 v6 规则追加，同样会落到 `ufw6-user-input`。
- 观测记录按位置追加：以写方式打开文件偏移从 0 开始，不加定位会覆盖最旧的记录。
- 探针由 daemon 监管：逐行读取子进程输出，bpftrace 退出即重启；daemon 重启后
  已安装的探针自动恢复；上一进程遗留的 bpftrace 会被替换而不是误判为运行中。

接口：`GET /api/v1/security/scan`，`POST /api/v1/security/scan/{install,start,stop,unban}`。

## 主机探测

主动探测向目标发包，因此只接受字面 IPv4 / IPv6 或 RFC 1123 主机名；网段、列表、
作用域 ID、前缀以及任何可能被读成 nmap 参数的值都被拒绝，nmap 始终以 argv
调用，不经过 shell。

- `nmap` 负责端口、服务与系统指纹；IPv6 目标自动加 `-6`。系统指纹需要 root，
  且 IPv6 的指纹库覆盖很差，结论通常为空——这会在报告里如实写出。
- Shodan InternetDB 作为免密钥被动情报补充；它没有 IPv6 索引，v6 目标只返回
  主动扫描结果。
- 扫描耗时以分钟计，因此注册为任务 `security.probe`，结果写入任务 `result`，
  人类可读摘要写入输出流。

边界：探测会暴露面板自身 IP，只能对授权目标使用；被动情报是第三方数据，仅作参考。

## 文件防篡改

用 `chattr +i` 实现：带不可变属性的路径即使 root 也无法改写、重命名或删除，
只有清除属性后才能维护。

- 目录自动递归（`chattr -R +i`）。只给目录本体加 `+i` 仍可在其中新建与重写文件，
  实测只有这样才真正阻断。
- 受保护路径记入 `<data>/security/tamper-manifest.txt`。daemon 启动时会逐条检查，
  属性丢失则重新应用并记录 `tamper: re-applied immutable flag on N path(s)`；
  重挂载、镜像重建或 fsck 都可能静默清除属性，静默失去保护正是该功能要避免的。
- 保护前先确认路径存在，避免清单记录一个不存在的目标。
- `chattr`/`lsattr` 缺失时状态如实上报，入口禁用。

接口：`GET/POST /api/v1/security/tamper`，`POST /api/v1/security/tamper/remove`。

## SELinux

按能力上报，不假定存在：

- `present` 取决于 `/sys/fs/selinux`。宿主使用 AppArmor（如 Ubuntu 默认）时该目录
  不存在，页面只显示"未启用"而不会给出无法生效的开关。
- 运行模式读自 `/sys/fs/selinux/enforce`，开机配置读自 `/etc/selinux/config`
  （忽略注释行）。`enforcing`/`permissive` 经 `setenforce` 立即生效；
  `disabled` 只能写配置，响应带 `reboot_required`，因为内核无法在运行时关闭。
- 布尔开关来自 `getsebool -a`，写入用 `setsebool -P`，且只接受策略实际声明的名字，
  避免拼写错误或注入内容进入命令。

接口：`GET /api/v1/security/selinux`，`POST /api/v1/security/selinux/{mode,boolean}`。

## 蜜罐

guest 在 QEMU/KVM 中运行，用宿主机自带内核 + busybox 构建 initramfs，不需要下载任何镜像。

硬件身份复刻，设备全部模拟：

- CPU 型号、核心数、内存大小与 DMI 字符串（厂商/型号/序列号）读自宿主机，作为
  QEMU 参数传入，攻击者看到的是"一台合理的机器"。
- 但没有任何设备透传：没有 PCI 直通，没有宿主机块设备，磁盘是自建 qcow2。
- 网络是 QEMU 用户态（slirp），guest 只能通过转发端口被访问，无法到达宿主所在
  局域网；每个会话生成独立的 `52:54:00` 前缀 MAC。
- 内存与 CPU 有上限（8 核 / 8 GiB），guest 不能把宿主机拖垮。

实现细节（都是实测踩出来的）：

- `-smbios` 的值按逗号分隔，而真实 DMI 里就有逗号
  （`CHUWI Innovation And Technology(ShenZhen)co.,Ltd`），不转义 QEMU 直接拒绝启动。
- `/init` 必须可执行，否则内核报 `Failed to execute /init (error -13)` 后 panic。
- `-nographic` 把串口接到 stdout，stdout 被管道接管时 QEMU 会立刻退出；因此改为
  `-display none -serial file:<console>`，由 QEMU 自己写控制台。
- 子进程必须有属主：否则会被立即回收成僵尸，控制台也拿不到。守护线程持有 Child
  并负责 `wait`。

任务：`security.honeypot.build`、`security.honeypot.start`（镜像构建与启动都不走同步请求）。

接口：`GET /api/v1/security/honeypot`、`GET /honeypot/console?id=`、`POST /honeypot/stop`。

### 诱饵内容

guest 里不是空的：每次构建都会生成一套"看起来像真机器"的内容，全部为伪造。

- 身份：随机主机名（如 `cache-prod-07`、`edge-us-east-11`）、发行版、
  `/etc/hostname`、`/etc/hosts`、`/etc/os-release`。
- 账户：`/etc/passwd`、`/etc/shadow`（随机但格式合法的哈希）、`/etc/group`、
  `root/.ssh/authorized_keys`、`root/.bash_history`（真实运维命令）。
- Web：随机主题的登录页、`robots.txt` 指向 `/admin/` 与 `/backup/`、
  以及一个"忘了删"的 `backup/config.php.bak` 含假数据库口令。
- 日志：`/var/log/nginx/access.log` 用标准 combined 格式
  （`26/Sep/2026:12:10:07 +0000`），`/var/log/auth.log` 用 `Sep  2` 格式，
  夹杂扫描路径与失败登录，来源地址取公共段且避开文档/私有网段。
- 配置：`/srv/app/.env`、`/etc/crontab`、nginx 站点配置与主机名一致。

同一次构建共用单个随机生成器，因此主机名、站点名与 nginx 配置互相吻合；
不同构建的镜像哈希不同，不会让攻击者在多次会话间看出是同一套模板。

## 主机加固

安全中心的「主机加固」页把常被漏掉的杂项集中在一处。每项都先读现状再写入受管
文件，重启后依然生效。

### 空链接

扫描 `/etc`、`/opt`、`/srv`、`/var/tmp`，用 `find -xtype l` 精确匹配**目标无法
解析**的链接（而非所有链接）。删除前会再解析一次：目标若已出现则跳过，避免误删
刚刚修好的链接。`-xdev` 只用于系统树，操作者选定的子树不加，否则 bind mount 会
让结果为空。

### 默认 umask

写入 `/etc/security/hampanel-umask.conf` 供 `pam_umask` 使用。umask 表示**要移除**
的权限位，因此校验规则是「其他用户必须失去写权限」（0o002 位必须存在）：
`027` 有效，`000` 会被拒绝。这一点最初写反了，测试立刻暴露。

### at / cron

写 `<tool>.allow` 并删除 `<tool>.deny`；两者同时存在时 allow 生效，留下的 deny
只会让审计困惑。用户名逐条校验，不接受空格、分号等可能进入命令的字符。

### sudo

写入 `/etc/sudoers.d/99-hampanel-hardening`（0440）。只包含 `use_pty` 与
`!visiblepw`——实测本机是 sudo-rs，`logfile` 这类项会报 `unknown setting` 并让
**所有** sudo 调用解析失败，因此写入后用 `visudo -c` 校验，不通过则回滚。

### 内核参数

只暴露 15 个有明确安全含义、且有安全取值的参数（ICMP、rp_filter、重定向、
syncookies、dmesg_restrict、kptr_restrict、sysrq、ASLR、protected_*）。取值写入
`/etc/sysctl.d/99-hampanel-hardening.conf` 并用 `sysctl -w` 立即生效；内核拒绝的
项会逐条报告，不会静默成功。

`net.ipv4.ip_forward` 标记为**需人工判断**：在容器宿主或路由器上关闭转发会直接
破坏网络（本机 `ip_forward=1` 且装了 Docker）。它被排除在「应用全部建议值」之外，
测试固定了这一行为。

接口：`GET /api/v1/security/hardening`，`POST /hardening/{dangling,umask,scheduler,sudo,kernel}`。

### SELinux 管理界面

有 SELinux 的主机按五个 Tab 打开，避免把上百项布尔值平铺成一屏：

- **概览**：当前/开机模式、策略类型、模块数量与列表。
- **布尔开关**：带搜索的逐项开关，写入用 `setsebool -P`，且只接受策略实际声明的名字。
- **文件上下文**：`semanage fcontext -C` 的本地定制，可增删；保存后执行
  `restorecon -R` 重打标签，因为 `semanage` 只记录规则、不改现状。
- **端口标签**：`semanage port -l`，可把端口绑定/解绑到类型。
- **拒绝日志**：`ausearch -m AVC,USER_AVC -ts recent`，展示权限、tclass、源/目标
  上下文与路径。

解析细节（都由解析器单测固定）：

- 上下文行的格式是 `<路径> <类别> <用户:角色:类型:级别>`，类别本身可能含空格
  （`all files`），因此从行尾解析；类型取第三个冒号字段，而不是最后一个
  （末尾常有 `:s0`）。
- `ausearch` 里 `path=` 可能与 `type=AVC` 同行，`audit(秒:序号)` 需单独提取。

校验先于能力检查：路径/类型/端口不合法时返回 400，即使主机没有 SELinux，这样
操作者能立刻看出是输入问题；输入合法但主机不支持才返回 409。

未启用 SELinux 的主机（如本机 Ubuntu + AppArmor）只显示"未启用"与开机配置，
不提供无法生效的开关，也不会自动修改内核启动参数。

SELinux 管理界面在真实主机上的验证要点（每一条都由运行时输出校准，不是推测）：

- `semanage fcontext -f` 只接受 `a/f/d/c/b/s/l/p` 单字母，而 `-l` 打印的是
  `all files` 这类词。两者必须做映射（`ftypeFlag`），直接透传会被工具拒绝。
- 列本地定制要用 `semanage fcontext -C -l`；`-C -n` 是非法组合，会被当成
  "缺少 -a/-d/-l"，结果看起来像"没有定制"。
- `ausearch -ts recent` 在部分主机上不解析日志而返回 `<no matches>`。改为
  `ausearch -if /var/log/audit/audit.log -m AVC,USER_AVC` 才能读到记录。
- 首次启用 SELinux 的主机必须完整 relabel（`touch /.autorelabel` 并重启），
  否则所有进程停在 `kernel_t`，既不产生有意义的 AVC，也没法验证域间行为。
  重打标签后 `init` 为 `init_t`、新进程为 `unconfined_t`，AVC 才正常记录。
- 输入校验先于能力检查：非法路径/类型/端口返回 400，主机不支持才 409。
