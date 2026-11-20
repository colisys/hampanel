# ClamAV 私有实例：目录扫描验收

依据：[官方 Scanning 手册](https://docs.clamav.net/manual/Usage/Scanning.html)（本站请求返回 HTTP 403，实际核对了 [Cisco-Talos 官方手册源文](https://github.com/Cisco-Talos/clamav-documentation/blob/main/src/manual/Usage/Scanning.md)）。本地 socket 模式下，clamd 可以直接读取目标；`clamdscan --multiscan` 允许目录扫描使用多个 daemon 工作线程。线程数由 clamd 配置 `MaxThreads` 控制。目标须对扫描账号可读，父目录可遍历。helper 不传 `--move`、`--remove` 或 `--copy`。

## 构建机实测

peiqianyun，Debian 12，ClamAV 1.4.6。Debian 包只下载并解包到临时目录，未安装；以 nobody 运行私有 clamd，用单条无害自定义 NDB 签名，无需系统服务或生产病毒库。验收脚本实际将带空格的绝对目录作为单个参数交给 helper，并非逐文件模拟目录扫描。

| 输入 | 实测结果 |
| --- | --- |
| 单个普通文件 / 写入测试标记后 | clean (0) / infected (1) |
| `target directory` 仅含 ordinary.txt | clean (0)，Infected files: 0 |
| 同目录加入 `nested/one.txt` 和 `nested/two.txt` | infected (1)，两个路径各报告 `HamPanelFixture.UNOFFICIAL FOUND`，Infected files: 2；两个文件内容未变 |
| 相对路径 | helper 退出 2，`expected absolute file or directory` |

括号中是扫描器退出码（JSON 的 `exit_code`），不是 helper 退出码。首次状态 inactive、初始化后 active、再次初始化 Already running；验收脚本退出 0，结束时确认私有 socket 消失。

复测：在 `clamd`、`clamdscan` 可从 PATH 找到的 Linux 环境，以非 root 身份从仓库执行 `python3 tool/clamav_acceptance.py`。TMPDIR 应可写且绝对路径足够短以容纳 Unix socket。此验收验证实际引擎、客户端和目录递归，不验证生产签名库更新或面板端到端部署。
