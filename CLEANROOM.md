# CleanRoom 声明

Hampanel 是独立实现的服务器运维面板。

## 实现方式

- 本项目所有源代码均为原创实现，按模块从零编写。
- 在设计与需求分析阶段，仅参考了以下项目的**公开产品介绍 / 功能清单**：
  - AcePanel（https://acepanel.net/quickstart/introduction，https://github.com/acepanel/panel）
  - 宝塔面板 BaoTa（https://github.com/aaPanel/BaoTa，https://www.bt.cn/）
  - aaPanel（https://github.com/aaPanel/aaPanel，https://www.aapanel.com/）
  - 1Panel（https://github.com/1Panel-dev/1Panel，https://docs.fit2cloud.com/1panel/）
- 仅参考「服务器面板通常提供哪些功能」这一层面（例如站点、文件、终端、容器、防火墙、计划任务等通用概念）。
- **没有**获取、阅读、复制、翻译或改写上述项目的源代码、配置模板、界面资源、文案、内部协议或专有算法。
- 本项目使用与所有参考项目完全不同的技术栈和协议：Zig 后端、Flutter 客户端、自研 HTTP/WebSocket 服务层、自研 mTLS 注册与证书体系；不采用参考项目的架构、数据模型或流程编排方式。

## 与参考项目的关系

- Hampanel 与 AcePanel、宝塔 / aaPanel、1Panel 及其维护者没有隶属、赞助或背书关系。
- 上述名称归其各自所有者所有，本项目仅将其作为功能层面的公开参考提及。

## 许可证边界

- 本项目以 **GPL-3.0-or-later** 发布，见 [LICENSE](LICENSE)。
- 第三方依赖（OpenSSL、Flutter/Dart 包）遵循其各自许可证，且与本项目许可证兼容。
- 贡献者提交代码即表示确认其贡献为原创或来自 GPL-3.0-or-later 兼容来源，并同意以 GPL-3.0-or-later 授权。
