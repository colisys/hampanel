# 移动端管理端

Android / iOS 客户端只做管理端，不运行 `hampaneld`。桌面端已有的功能在移动端
按平台能力做了取舍。

## 启动与本地数据

- 配置目录在启动时由 `path_provider` 解析：Android 为应用私有目录
  `/data/user/0/work.dawncall.hampanel/files/hampanel`，iOS 为 Application Support。
- 启动页会列出本机保存的所有服务器（别名、端点、客户端 CN、入口前缀、添加时间），
  选择一台即可连接；同一页可以添加新服务器或通过 SSH 安装。
- 启动页和首次导入页都提供「管理端更新」：可直接检查 stable/nightly 通道并下载
  对应平台的客户端，不需要先连上任何服务器。
- 「断开连接」只关闭当前会话、停止向目标发送请求，不会删除服务器记录或注册凭据；
  下次启动或断开后仍可在列表中选择。删除服务器需要显式确认。
- 首次启动失败不会再无限转圈：引导页会显示错误信息、配置目录与「重试」按钮。
- SQLite、注册凭据、AI 会话、客户端设置都保存在该私有目录内；卸载应用即清除。

## 平台能力差异

| 能力 | Android / iOS | 说明 |
| --- | --- | --- |
| 文件上传 | Storage Access Framework | 通过 `ACTION_OPEN_DOCUMENT` 选择文件，不需要存储权限，单文件上限 256 MiB |
| 文件下载 | SAF 保存 | `ACTION_CREATE_DOCUMENT` 让用户选择保存位置 |
| 打开外部链接 | `ACTION_VIEW` | 客户端自更新、发布页链接交给系统浏览器 |
| 端口穿透 | 隐藏 | 依赖本机 `ssh` / `socat`，移动端不提供 |
| 打开配置目录 | 隐藏 | 移动端没有桌面文件管理器入口 |
| AI Key | 应用私有文件 | 沙箱保存 `files/hampanel/ai_key`；桌面端仍使用系统钥匙串 |
| 系统时间 | 本地时区 | 所有时间戳统一格式化为本机时区 |

## 布局

- 主菜单：宽度 < 900px 时侧栏收起为抽屉，顶栏汉堡按钮打开；选择菜单、切换主机、
  管理主机、断开连接都会自动关闭抽屉。
- 二级菜单：设置（常规 / AI / 主机 / 关于）与 SSH（概览 / 密钥 / 日志）在
  宽度 < 720px 时变成标题栏上的小汉堡弹层。
- 页面标题：动作按钮在宽度 < 900px 且多于一个时自动换行到标题下方。
- 对话框：统一使用 `DialogBody`，按屏幕尺寸收敛宽高。
- 表单：`FormRow` / `FieldWithActions` 在窄屏让每个编辑框独占一行，按钮换到
  字段下方；桌面端保持并排。
- 字体：系统字体缩放被限制在 0.85–1.25 之间，避免超大字号撑破布局。
- 返回键：优先关闭“主机管理”内嵌页，其次是抽屉，最后退出应用。

## 构建与签名

Android 使用 Flutter 工程 `app/android`，`flutter build apk --release` 即产出
universal APK。CI 从仓库 secrets 还原 keystore 后签名（v2 + v3）：

- `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`

本地构建可设置同名环境变量（`HAMPANEL_ANDROID_KEYSTORE` /
`HAMPANEL_ANDROID_KEYSTORE_PASSWORD` / `HAMPANEL_ANDROID_KEY_ALIAS` /
`HAMPANEL_ANDROID_KEY_PASSWORD`）。没有签名材料时构建不中断，但产物为
`-unsigned.apk`。

iOS 由 CI 以 `--no-codesign` 构建并打包成未签名 IPA，安装前需要自行签名。
