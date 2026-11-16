# 品牌：8-bit 火腿标志

产品名 Hampanel，标记取「ham」火腿：一块带骨、带肥边的像素火腿，向 8-bit 时代致意。

## 资产

| 路径 | 用途 |
| --- | --- |
| `app/assets/branding/hampanel-ham.svg` | 矢量源（32×32 网格，`shape-rendering="crispEdges"`） |
| `app/assets/branding/hampanel-ham.png` | 透明底 512px，用于应用内标题与登录页 |
| `app/assets/branding/hampanel-ham-icon.png` | 1024px 米色底，用于商店/预览 |

平台图标由同一网格生成：Android `mipmap-*`、自适应图标（`ic_launcher_foreground`
/ `ic_launcher_background` / `ic_launcher_monochrome`）、Windows `.ico`、
macOS 与 iOS 的 `AppIcon.appiconset`。Android 启动页使用
`drawable/launch_logo.png` 与米色背景。

## 调色板

| 名称 | 值 | 用途 |
| --- | --- | --- |
| Ink | `#161616` | 描边、深色文字 |
| Paper | `#F3EEE2` | 背景、肥边 |
| Accent | `#D7263D` | 火腿主体 |
| Deep red | `#8E1B1B` | 暗部 |
| Pink | `#EA6B74` | 亮部 |
| Highlight | `#F8B0B0` | 高光 |
| Bone | `#FFFBF3` | 骨头 |

## 使用规则

- 最小尺寸 16px；放大请使用最近邻（`FilterQuality.none`），保持像素边缘。
- 透明底版本只放在浅色表面上；深色背景请使用米色底图标版本。
- 不要拉伸、旋转或添加投影；需要留白时按 3 像素网格取整。
