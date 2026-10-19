# 大肥鱼build整合 · DSH 本地视觉模型一键包（开源的是"安装器"，不是模型）

> **这个仓库只有安装器、网关和界面源码（约 300 KB）。** 6 GB 的模型权重、llama.cpp 二进制、
> 以及从你本机 DSH 里提取的依赖，**一律不在仓库里** —— 它们要么受各自的许可证约束，
> 要么属于 DeepSeek Harness 的专有内容，不能公开分发。

---

## 这是什么

给已经装好 [DeepSeek Harness](https://github.com/deepseek-ai)（DSH）的 Windows 机器，一键加一个
**本机运行的视觉模型**（Qwen3-VL-4B，走 llama.cpp）。装完之后 DSH 的模型列表里多一个
`local-gguf / local-vl`，可以看图、也可以委派批量文字活儿。

设计原则：

| 原则 | 怎么做到的 |
|---|---|
| 离线 | 模型、运行时、插件都在包里，安装不联网 |
| 可验证 | `verify.ps1` 逐文件 SHA256，`manifest.json` 记录上游哈希 |
| 可回滚 | 所有改动都有 `.bak`，卸载只删自己加的 |
| 不伤存量 | `-AllowMultiple` 之外只认一份安装；卸载不碰用户自己的插件 |
| 硬件自适应 | 探测 CUDA / Vulkan / CPU 三套构建，按显存挑 4B 或 2B |

## 仓库里有什么 / 没什么

| 有 | 没有（以及原因） |
|---|---|
| `install.ps1` `uninstall.ps1` `verify.ps1` `smoke.ps1` | 模型权重 `.gguf`：许可证与体积都不适合放 GitHub |
| `gateway/`（OpenAI 兼容网关，`gateway.js` 等） | llama.cpp 二进制：从官方 release 现取，见 `scripts/` 说明 |
| `gateway/rules/AGENTS.block.md`（写进 DSH 的调用规则） | 第三方插件：从 npm 装，本仓库只记录版本 |
| `src/`（WinForms 启动器 `Starter.cs`） | DeepSeek Harness 本身及其 `@deepseek-ai/*` 包 |
| `docs/`（第三方声明、开发者文档、隐私、安全） | 安装包本体（6 GB 的 `payload/`） |

## 装之前

1. Windows 10/11 x64
2. **DSH 已安装，并且至少启动过一次** —— 安装器要读 `%USERPROFILE%\.dsh\profiles\desktop`
   和 DSH 自带的 node 运行时
3. 磁盘 ≥ 8 GB（4B 模型约 3.2 GB + 运行时 0.8 GB）
4. 显卡可选：没有 NVIDIA 也能装，会落到 CPU 构建（慢，但能跑）

## 安装

```
1. 完全退出 DSH（托盘图标右键 → 退出）
2. 双击 新手向大肥鱼build整合.exe，选目录，勾插件，点「一键安装」
3. 装完打开 DSH，模型列表里出现 Local VLM (auto start/stop)
```

命令行等价：

```powershell
.\install.ps1 -Apply -TargetDir "D:\DSH-LocalLLM" -WithPlugins `
  -PluginNames "dsh-better-sidebar,dsh-context,dsh-whale-widget,dshmarket" -RestoreSettings
```

不带 `-Apply` 是干跑，只打印计划、不写任何东西。

## 卸载

按「卸载」按钮，或：

```powershell
.\uninstall.ps1 -Apply -TargetDir "D:\DSH-LocalLLM"            # 只删模型与配置
.\uninstall.ps1 -Apply -TargetDir "D:\DSH-LocalLLM" -RemovePlugins   # 连四个插件一起删
```

卸载的行为边界（写在代码里，也有测试守着）：

- 删：安装目录、写进 `cordis.patch.yml` 的配置块、`AGENTS.md` 的规则块、开机自启
- 不删：DSH 本身、你自己装的插件（**哪怕同名同版本**）、`node_modules` 里的公共依赖
- `-RemovePlugins` 也只删**版本与本包一致**的那四个；你升级过的会被跳过并告诉你

## 已知限制

- 本地 4B 生成速度约 **5–14 tokens/s**（RTX 3050 Laptop 实测），只适合看图/识字，长文不划算
- 精确字数、算术类任务本地模型做不好（会数错、会循环），规则里明确禁止委派
- 只支持 Windows
- DeepSeek Harness 升级可能改变内部结构；安装器会重新探测，但若失败请提 issue

## 许可与合规

- 本仓库代码：**MIT**（见 `LICENSE`）
- 第三方组件：见 `docs/THIRD-PARTY-NOTICES.md`；本仓库**不包含**它们的二进制
- 隐私：不收集任何遥测，网关只监听 `127.0.0.1`，见 `docs/PRIVACY.md`
- 安全：漏洞请勿公开提 issue，见 `SECURITY.md`
- 免责：模型输出不可靠，见 `DISCLAIMER.md`

## 状态

实验性项目。安装器在 Windows 10/11 + DSH 0.2.x 上验证过；欢迎 issue/PR。