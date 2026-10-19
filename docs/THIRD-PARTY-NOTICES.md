# Third-Party Notices / 第三方组件声明

本仓库（源码）**不包含**任何第三方二进制。安装器在运行时从各上游获取它们。
下面列出的每一项，都说明它的许可证、我们从哪里取、以及为什么不在仓库里。

## 1. llama.cpp

- 许可证：**MIT**
- 上游：https://github.com/ggml-org/llama.cpp
- 我们怎么用：从官方 GitHub Release 下载 Windows x64 的三套构建（CUDA / Vulkan / CPU），
  逐个文件核对 SHA256 后打进安装包。
- 为什么不在仓库：单套构建 48–713 MB，超过 GitHub 的合理体积。
- 你自行构建时请遵守 MIT：保留版权声明与许可文本。

## 2. Qwen3-VL 模型权重

- 模型：Qwen3-VL-4B-Instruct、Qwen3-VL-2B-Instruct（GGUF 量化版）
- 上游：ModelScope / Hugging Face 的 Qwen 官方仓库
- 许可证：以模型卡为准（Qwen 系列通常为 **Apache-2.0**）。**下载与再分发前请自行确认模型卡当前条款。**
- 我们怎么用：从 ModelScope 下载原始 GGUF，记录公布哈希，安装时释放到 `models\<name>\`。
- 为什么不在仓库：3.2 GB；且模型许可可能有附加使用条款。

## 3. 随包安装的四个 DSH 插件

以下插件**由各自作者发布**，本仓库只记录版本号，安装时从 npm 取（离线包则预先下载）。

| 插件 | 版本 | 许可证 | 上游 |
|---|---|---|---|
| dsh-better-sidebar | 0.26.1 | **MIT** | https://github.com/omdsh-dev/DSH-better-sidebar |
| dsh-context | 0.72.0 | **Apache-2.0** | https://github.com/bowenliang123/dsh-context |
| dsh-whale-widget | 0.4.2 | **MIT** | https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget |
| dshmarket | 1.66.22 | **MIT** | https://github.com/dsh-market/dsh-market |

- 再分发时：MIT 的保留版权与许可；Apache-2.0 的还要保留 `NOTICE` 并声明是否修改（见根目录 `NOTICE`）。
- 我们**没有修改**这些插件的代码，只是原样复制到 profile 的 `node_modules`。

## 4. DeepSeek Harness 及其 `@deepseek-ai/*` 包

- **不随本仓库分发，也不应被再分发。**
- 安装器只在**用户本机已安装的 DSH** 上工作：从 `app.asar` 里提取该用户自己那份依赖，
  补到自己的 profile 里。这是"在你的机器上使用你已安装的软件"，不是分发。
- 如果你 fork 本项目，请保持这个边界：**不要把你的 `profile-snapshot/` 提交上来**。

## 5. LibreOffice Kit（Office 转换用）

- 由 DSH 提供（`@deepseek-ai/libreoffice-kit-win32-x64`），安装器只会从用户已装的 DSH 中提取。
- 不随仓库分发。

## 6. 其他依赖

网关只使用 Node.js 内置模块（`node:http`、`node:fs` 等），没有第三方 npm 依赖。
安装器只使用 Windows PowerShell 内置命令。