# 回收站与文件历史版本

## 回收站

通过面板删除文件时，内容不会直接从磁盘消失：

- 文件/目录被移动到 `<data_dir>/recycle/<id>/payload`；
- 元数据（原路径、名称、类型、大小、删除时间）写入同目录 `meta.json`；
- 跨文件系统时使用递归复制后删除原路径；复制失败不会删除原文件；
- 原路径位于面板数据目录内时拒绝回收，避免递归。

API：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/recycle` | 列出回收站 |
| POST | `/api/v1/recycle/restore` | `{id}` 恢复到原路径 |
| POST | `/api/v1/recycle/delete` | `{id}` 永久删除单项 |
| POST | `/api/v1/recycle/empty` | 清空回收站 |

恢复时如果原路径已存在会返回冲突。永久删除与清空仅在「回收站」页面显式确认后执行。

## 文件历史版本

保存文件（在线编辑、上传覆盖、AI 写入）前，daemon 会把旧内容复制到：

```
<data_dir>/versions/<sha256(path)>/<version-id>.blob
```

元数据保存在同目录 `meta.json`，最多保留每个文件最近 20 个版本。版本内容存放在
面板管理数据目录，不会在文件所在目录创建 `.versions` 等隐藏目录。

API：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/files/versions?path=` | 版本列表 |
| GET | `/api/v1/files/versions/content?path=&id=` | 版本内容（UTF-8 或 base64） |
| POST | `/api/v1/files/versions/restore` | `{path,id}` 恢复版本 |

恢复前会自动把当前内容保存为新版本，恢复操作本身也可以回退。
