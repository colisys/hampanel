# Supervisord 面板实例

依据官方 [Running Supervisor](https://supervisord.org/running.html)、[配置](https://supervisord.org/configuration.html) 和 [XML-RPC API](https://supervisord.org/api.html)。实例仅使用 `<data_dir>/supervisord`，目录须为可信绝对路径、归 daemon 用户所有且权限 0700。路径须足够短以容纳 Unix socket 及 Supervisor 临时 PID 后缀。不读取 `/etc/supervisor`，不注册 systemd 服务。启动前可由管理员放入 `programs/*.ini`；启动操作不会覆盖这些文件，也不会重载正在运行的实例。

## 集成清单（共享文件未改）

- `daemon/src/api/mod.zig`：导入 `supervisord.zig`，注册 GET `/api/v1/supervisord` → `list`、POST `/api/v1/supervisord/action` → `action`，沿用软件管理鉴权与审计。POST 字段 `action`、`name`（完整 `group:process`）、`stream`（stdout/stderr）；launch 不需要 name。
- `daemon/src/platform/linux/software.zig`：在软件列表中登记 `supervisord`；探测 `supervisord --version`，用专属实例 RPC 状态判断 active，不以系统服务状态代替。面板的启动按钮直接调用 launch，不要走通用 systemctl 启停。
- `app/lib/features/software/software_page.dart`：在对应 software card 后挂载 `SupervisordPanel.connected(_api)`，未初始化时也显示启动按钮。
- Linux 打包：确保 daemon 的可信 PATH 内有 Python 3、`supervisord` 和 `supervisorctl`。helper 通过 Python 标准库访问私有 Unix socket。helper 已嵌入 Zig，不需复制 Python 文件。

## 独立测试

在装有上述依赖及 `supervisorctl` 的隔离环境执行 `python3 test_managed.py`。测试只关闭自己用 `-c` 启动的实例。Flutter 工程内执行 `flutter test test/supervisord_panel_test.dart`。
