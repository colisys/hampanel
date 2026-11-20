# Pure-FTPd 独立接线清单（Linux）

上游依据：[README.Configuration-File](https://github.com/jedisct1/pure-ftpd/blob/master/README.Configuration-File) 规定配置文件直接作为唯一位置参数；[README.TLS](https://github.com/jedisct1/pure-ftpd/blob/master/README.TLS) 区分 TLS 2（要求加密登录）与 TLS 3（同时要求加密数据）；[README.Virtual-Users](https://github.com/jedisct1/pure-ftpd/blob/master/README.Virtual-Users) 规定用 pure-pw 管理源文件、mkdb 发布 PureDB、`-d` 限制虚拟用户根目录。不是 SFTP，也不是隐式 FTPS。

* 部署：将 `daemon/libexec/pure_ftpd.py` 安装到 `/usr/local/libexec/hampanel/`，将 `deploy/hampanel-pure-ftpd.service` 作为独立 unit 打包。不替换发行版 pure-ftpd.service。依赖 Python 3、支持 TLS/PureDB 的 Pure-FTPd 和 pure-pw。预置专用非 root、无登录 shell 的 hampanel-ftps 系统账号和组。将实际证书链与私钥 PEM 放到 `/var/lib/hampanel-ftps/server.pem`，由 root 持有且文件权限为 0600；实例目录权限为 0711，以便虚拟用户进入自己的 home。不要将自签测试证书用于部署。默认仅回环 2121，对外开放前另行审核绑定、防火墙、被动端口和证书主机名。
* `daemon/src/api/mod.zig`：在与 fail2ban 相同的已认证管理路由注册 POST `/api/v1/pure-ftpd/{initialize,add,delete}`，分别对应 `api/pure_ftpd.zig` 的 `initialize/add/remove`。add 请求 `{name,password}`，delete 仅 `{name}`；禁止记录请求体。仅 Linux 暴露。
* `daemon/src/platform/linux/software.zig`：软件列表用 id `pure-ftpd`，探测 pure-ftpd 和 pure-pw，初始化标记为专属配置，active 使用专属 unit 的 is-active 退出码。不要探测发行版服务作为本实例状态。
* `app/lib/features/software/software_page.dart`：在对应卡片加载 `PureFtpdControls`，从列表传 initialized，回调分别 postJson 到上述三个路由；成功后刷新。保留目录的账号删除操作建议由调用页面二次确认。
* 验收：PATH 指向隔离的 Pure-FTPd bin/sbin 后执行 `python3 tool/pure_ftpd_acceptance.py`。仅启动一个回环临时进程组，不操作 systemd。非 root 构建覆盖 FTPS 与 PureDB 行为，不证明 Linux 内核 chroot 或 unit 权限。在有 Flutter SDK 的环境从 app 执行 `flutter test test/pure_ftpd_controls_test.dart`。
