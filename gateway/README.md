# DSH 本地 GGUF 子代理（llama.cpp）

把 `D:\DSH-LocalLLM` 里的千问 Omni 模型接成 DSH 的一个模型路由，主模型可以把简单任务
委派给它，也可以在纯文本主模型（如 V4pro）下用它补多模态。

关键点：**你不需要手动开服务**。网关常驻但只占几十 MB 内存，真正的 `llama-server`
在第一次真正调用时才启动，空闲到点自动退出并释放显存。

## 架构

```
DSH 主会话（deepseek-flash / V4pro，纯文本）
   │  subagent 工具带上 provider=local-gguf, model=qwen2.5-omni-3b
   ▼
gateway.js          常驻 127.0.0.1:8099，无模型权重，约 40 MB
   │  第一次真实请求 → 启动；空闲 5 分钟 → 关掉
   ▼
llama-server.exe    127.0.0.1:18080，只在需要时占 2.2 GB 显存
```

为什么要中间这一层：llama-server 自己不会按需启动，DSH 也不会替你拉起外部进程。
网关把这两件事接起来，同时补上 DSH 到本地模型之间缺的两块：

- `/v1/models` 由配置直接回答，**浏览模型列表不会加载权重**。
- 提示词里出现的本地图片路径会被自动读出来，转成 `image_url` 附件再送进模型。
  纯文本主模型只要在委派提示里写下图片路径，本地模型就能真的看到图。

## 文件

| 文件 | 作用 |
|---|---|
| `gateway.js` | 网关本体，无第三方依赖 |
| `config.json` | 全部可调参数，改完保存即生效，不用重启网关 |
| `launch-gateway.vbs` | 隐藏窗口启动网关（自启动用） |
| `gateway-control.cmd` | `start` / `stop` / `status` / `unload` / `logs` |
| `selftest.mjs` | 8 项自检：冷启动、文本、图片、流式、显存回收 |
| `ask-image.mjs` | 命令行问一张图，例如 `node ask-image.mjs 图片路径 "读出所有文字"` |
| `test-vision-shapes.mjs` | 看图回归测试：同一张图分别以字符串和 parts 数组两种形态送进去 |
| `test-capability.mjs` | 10 项能力边界测试，跑出"可委派/不可委派"清单 |
| `test-guards.mjs` | 防护测试：并发、超长提示、越界后恢复 |
| `validate-config.cjs` | 校验 `cordis.patch.yml` 里本方案的两块配置是否符合 DSH 的 schema |
| `probe-vision.png` / `probe-smalltext.png` | 看图测试用图（模型事先没见过的内容） |
| `logs\` | `gateway.log`、`llama-server.log`、`launcher.log` |

DSH 侧的配置在 `%USERPROFILE%\.dsh\profiles\desktop\cordis.patch.yml` 末尾，
新增了 `llm-pi-ai`（`local-gguf` 路由）和 `subagent-model-selection-settings`（允许主模型选择该路由）两块。

## 启用

配置已经写好，**重启一次 DSH 桌面端**让它完整加载。实测：不重启时，即使新建一个子代理会话，
DSH 仍按旧策略运行（委派时报 `child model selection is disabled for this tool instance`），
所以这一步不能省。重启后**新开一个会话**即可。

### 怎么才算真的重启

**点右上角的叉不算**。DSH 会拦截窗口关闭事件，只是把窗口隐藏到系统托盘，Host 进程继续跑，
配置不会重载。要彻底退出，任选一种：

1. 任务栏右下角 `^` 里找到 DSH 图标 → 右键 → 「退出 DeepSeek Harness」，再从桌面/开始菜单重新打开；
2. 窗口里按 `Alt` 唤出菜单栏（默认自动隐藏）→ 菜单里「退出」；
3. 任务管理器结束所有 `DeepSeek Harness` 进程，再重新打开。

退出时如果别的会话还有正在跑的任务会被一并中断，留意一下。
网关是独立进程，不受 DSH 退出影响，不用重新启动。

在新会话里，让主模型委派到本地模型的提示词例如：

```
把下面这段内容交给本地小模型做：用 qwen2.5-omni-3b 总结成三句话。
```

主模型会自动带上 `provider=local-gguf`、`model=qwen2.5-omni-3b`。不指定时子代理仍然走主模型原来的路由，
所以原有行为不变。

看图（主模型是纯文本模型时）：

```
让本地模型看一下 D:\DSH-LocalLLM\test-image.png，描述里面有什么。
```

子代理提示里只要有这个路径，网关就会把图片附上。也可以只写文件名（如 `test-image.png`），
会在 `features.imageSearchDirs` 里递归查找。

## 显存与速度（本机实测：RTX 3050 Laptop 4 GB）

当前 `config.json` 用的是**稳当档**，留足余量给桌面和浏览器：

| 项目 | 稳当档（当前默认） | 快速看图档 |
|---|---|---|
| 显存占用 / 剩余 | 约 2.5 GB / **1.42 GB 空闲** | 约 3.9 GB / 约 90 MB 空闲 |
| 文本生成 | 约 48 tok/s | 约 47 tok/s |
| 冷启动（含拉起服务） | 约 3.9 s | 约 6 s |
| 每张新图片 | 约 8 s | 约 1.5 s |
| 配置差异 | 带 `--no-mmproj-offload`、`--image-min-tokens 256` | 去掉前者、后者改 512 |

只有 4 GB 显存时视觉投影器（1.43 GB）放 GPU 会让整卡几乎占满，桌面会卡；稳当档把它放 CPU，
多花几秒换 1.7 GB 余量。想要更快的看图，把 `config.json` 里 `llamaServer.args` 改成：

```json
"-ngl", "99", "-c", "16384", "-np", "1", "-fa", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0", "--image-min-tokens", "512"
```

（即删掉 `--no-mmproj-offload`，`256` 改 `512`。）保存后执行 `gateway-control.cmd unload`，下次请求按新参数起。

空闲多久释放显存由 `lifecycle.idleTimeoutMs` 控制，默认 300000（5 分钟）。想立刻释放：
`gateway-control.cmd unload`。

## 看图能力实测

用模型事先没见过的图测的，图里的答案从未出现在提示词里：

| 测试 | 结果 |
|---|---|
| 简单图形图（640×320）：读出文字 | **完全正确**，`VISION OK 42` 一字不差 |
| 背景色 / 图形颜色 | 正确（紫色背景、绿色三角形、黄色圆圈） |
| 图形是实心还是空心 | **错**：把空心圆说成实心（三角形说对了，不是一律瞎猜） |
| 单据图（900×400）：逐行读全部文字含 15px 小字 | **完全正确**，单号、金额、日期、客户名全部读对 |
| 同一张图再问一次 | 约 1.7 s（图片编码被缓存），换新图才付全额时间 |

`--image-min-tokens` 我实测过 256 和 512 两档：**小字识别和实心/空心判断都没有区别**，
512 只是多花约 2～3 秒。所以默认 256。不要指望调这个参数修掉属性类错误，那是 3B 模型本身的能力边界。

耗时主要取决于**图有多大**、以及是不是第一次见：640×320 约 8.7 s，900×400 约 17 s，
之后同一张图约 1.7 s。所以让主模型「一次问清楚」，比反复问同一张图划算。

## 能力边界（10 项实测，可复跑 `test-capability.mjs`）

| 测试 | 结果 |
|---|---|
| 英译中 | ✅ 准确 |
| 严格 JSON 抽取（指定键名） | ✅ 键与值、数字全对 |
| "只输出指定内容" | ✅ 遵守 |
| 简单逻辑推理 | ✅ 正确 |
| 长文找关键信息（5600 token） | ✅ 命中 |
| 缺信息时不编造 | ✅ 会说材料里没有 |
| 长文本不退化 | ✅ 557 字无重复循环 |
| 抗提示注入 | ✅ 没被资料里的指令劫持 |
| **精确字数约束**（要求 ≤40 字） | ❌ 给了 137 字 |
| **多步算术**（17*23+9） | ❌ 答 422（正确 400） |

结论：**"读输入 → 产出结构化内容"很稳；"算数和自我量化"不可靠。**
连续三次复跑失败项稳定，不是偶发。

## 调用规则与防护

### 规则存在哪

`%USERPROFILE%\.dsh\AGENTS.md`。DSH 的 `agent-instructions` 会以 65536 字节预算
把它作为**全局基线**注入每一个会话，先于任何项目 `AGENTS.md`，因此**换会话、换工作区都有效**。
（本项目里创建该文件后立即就被注入了当前会话，机制已验证。）

规则内容按上面的实测边界写成"可委派 / 不要委派 / 怎么写 / 稳定性要求"四段，
其中最关键三条：算术结果要主模型自己算、它给的测试用例和事实断言必须复核、
本地路由失败就放弃而不是重试。

### 为什么不拆成按需加载的 skill

考虑过把规则拆成"常驻指针 + 按需 skill"，用本机真实会话数据算过账，结论是不值得：

| 指标 | 实测 |
|---|---|
| 整份 AGENTS.md | 683 tok（Qwen 词表精确分词） |
| 大会话单步上下文 | 160k ~ 440k tok |
| 683 tok 占单步上下文 | **0.16% ~ 0.43%（中位数 0.23%）** |
| 全部会话输入合计 | 64,507,522 tok，其中 **99.38% 是缓存读** |
| 拆成 skill 后常驻 | 163 + 82 = 245 tok，省 438 tok/请求 |

省下的 438 token 相当于把单步上下文减少 0.15%，而它本来就是按缓存读计价的。
同时 skill 目录条目是被动的：用户说"看看这张图"时，提示词里并没有"小模型"三个字，
很可能**永远不会被触发** —— 装好了却用不上，比多占 683 tok 糟得多。

所以规则保持常驻。想省 token，杠杆在**缩短上下文和压缩工具输出**，不在这份规则。
`tools/session-usage.cjs` 可以随时复算这笔账。

### 即使主模型无视规则，也不会出事

规则是"软"的（依赖模型遵守），所以网关和配置里另加了"硬"约束：

| 风险 | 防护措施 | 实测 |
|---|---|---|
| 残留 llama-server 占卡、新网关起不来 | 启动前探测上游端口，确认是 llama-server 才杀，再自己启动 | 100 ms 回收成功 |
| 显存被两份模型占满 | 单端口单上游 + 网关单实例（端口占用即退出）+ `-np 1` 串行 | 并发 3 请求全成功，显存不变 |
| 启动失败反复拖住主任务 | 连续失败 2 次后熔断 60 秒，期间秒拒 | 前两次 0.6 s 失败，第三次 0 ms |
| 修好配置还要干等熔断 | 检测 config.json 变更（按代次，不看 mtime 回退）立即解除 | 恢复后 3.6 s 正常 |
| 生成卡死无限等待 | `streamIdleTimeoutMs: 90000` + 网关上游超时 | — |
| 本地不可用时被反复重试 | DSH 侧 `retryPolicy.maxRetries: 1` | — |
| GPU 被别的程序占了导致起不来 | 识别分配失败后自动降级一次：投影器挪回 CPU，文本仍可用 | 诊断信息可读 |
| 提示词超长 | llama-server 直接 400 并给出实际 token 数，网关不崩 | 41 ms 拒绝，随后正常 |
| 网关进程挂了留下孤儿 | 退出钩子尽力杀子进程；下次启动仍会回收 | — |

想撤销熔断立刻重试：`gateway-control.cmd` 或
`Invoke-RestMethod -Method Post http://127.0.0.1:8099/gateway/reset`。

## 控制与自检

```
cd D:\DSH-LocalLLM
gateway-control.cmd status    显存/模型状态（JSON）
gateway-control.cmd unload    立刻释放显存，网关留着
gateway-control.cmd stop      释放显存并关掉网关
gateway-control.cmd start     手动启动网关（平时随登录自动启动）
gateway-control.cmd logs      跟踪网关日志

"%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe" selftest.mjs
```

`selftest.mjs` 里那几行「vram ... nvidia-smi unavailable」是正常的：在 DSH 工具沙箱内运行的子进程
无法读取 `nvidia-smi` 的输出，换到普通命令行窗口跑就会显示显存数字。

自启动方式是「启动」文件夹里的 `DSH Local LLM Gateway.lnk`，登录时隐藏运行 `launch-gateway.vbs`。
想取消自启动，删掉这个快捷方式即可（位于
`%USERPROFILE%\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup`）。

## 已知限制

- **这个 3B 模型本身不会调用工具**：它的对话模板没有 tools 段，实测传 tools 也不会产生工具调用。
  所以它适合做「读一段文字→产出结论」「看图说话」这类一次问答，不适合需要自己翻文件、跑命令的多步任务。
  看图的路径因此改成由网关自动附图，而不依赖模型去调工具。
- **上下文 16384**：`-c 16384` 且 `-np 1`，超长委派会被截断或报错；同时发来的第二个本地请求会排队。
  实测 3900 token 的提示词约 5.5 秒处理完（含冷启动）。
- **音频/视频用不上**：llama.cpp 这个 mmproj 支持 audio、video，但 DSH 的 pi-ai 适配器只声明
  `text` / `image` 两种输入模态，所以从 DSH 只能走文本和图片。
- 网关没运行时，DSH 调用该路由会直接报错（`local model unavailable`）。看 `logs\gateway.log`。

## 附：2026-10-17 二次改造（换模型 + 修网关）

评测发现旧配置下本地模型作为 DSH 子代理会**整张图编造**（返回 CPU/内存/硬盘/网络一套
图上根本没有的指标，并断言"报错：无、页脚：无"）。根因有两个，都不在模型本身。

### 修复 1：剥离 DSH 的系统提示（`features.systemPrompt.mode = "strip"`）

DSH 每次委派都带整套编码 agent 系统提示。同一张图、同一提示词，只改这一项：

| 系统提示规模 | 剥离前 | 剥离后 |
|---|---|---|
| 1.9k tok | 指标对，**报错/告警答"无"** | 指标 + 报错全部正确 |
| 3.3k tok | 同上 | 同上 |
| 4.6k tok | 同上 | 同上 |

四档里三次误报"无报错"，而图上有两条告警。剥离后四档输出完全一致且正确。
网关日志会记录 `system prompt stripped: N message(s), M chars removed`。

### 修复 2：图片 token 256 → 512

页脚（`build 4f2c9a - env prod-cn-east`）在 256 档一律答"无"，512 档能正确读出，
耗时只多约 1 秒。

### 换模型实测

统一用 `tools/bench-vision.mjs` 打分（12 项可独立核对的图上事实：标题、4 个指标、
GPU 面板、两条告警、页脚两段）：

| 模型 | 量化 | 视觉得分 | 读取耗时 | 加载后空闲显存 | 文本能力 |
|---|---|---|---|---|---|
| Qwen2.5-Omni-3B（初始） | Q3_K_M | 11/12 | 21.0 s | 1318 MB | 8/10 |
| Qwen3-VL-2B | Q4_K_M | 11/12 | 13.1 s | 1305 MB | 8/10 |
| **Qwen3-VL-4B（当前）** | **Q4_K_M** | **12/12** | 17.4 s | 137 MB | 8/10 |

- 2B 快、余量足，但标题 OCR 会错（`INFERENCETGATEWAY`）；4B 满分但显存吃紧。
- 三者文本能力都是 8/10，失败项一致：算术（3B 答 422，4B 退化成 `399 + 9 = 399 + 9…` 循环）
  与精确字数约束。**换模型解决不了这两项**，规则里已标注不要委派。
- 试过 `--cache-type-v q4_0` 压显存：得分不变但耗时从 18 s 涨到 89 s，已弃用。
- 试过把上下文从 16384 降到 12288：只省 75 MB（compute buffer 是大头），已回退。
- 试过 Qwen3-VL-4B 的 Q3_K_M（权重少 403 MB）：同样 12/12、同样快，但显存只省 **54 MB**
  （3772 vs 3826）。**换量化买不到余量** —— 4B 的占用是 compute buffer 撑的，不是权重。
  既然显存一样，就用质量余量更大的 Q4_K_M。

### 当前配置

- 模型：`D:\models\qwen3-vl-4b\Qwen3-VL-4B-Instruct-Q4_K_M.gguf` + `mmproj-F16.gguf`
- 参数：`-ngl 99 -c 16384 -np 1 -fa on --cache-type-k/v q8_0 --no-mmproj-offload --image-min-tokens 512`
- 加载后显存约 3.83 GB（4 GB 卡剩 137 MB），空闲 5 分钟自动卸载回到 327 MB
- 路由 id 改为 `qwen3-vl-4b`，`cordis.patch.yml` 与 `AGENTS.md` 已同步
- 旧 id `qwen2.5-omni-3b` 在重启 DSH 前仍可用：网关会把请求里的 model 字段改写成当前 alias

## 附二：2026-10-17 第三轮优化（多图基准 + 显存自适应）

### 先补一个方法论漏洞

之前的 12/12 只用了**一张图**，有过拟合风险。新增 `tools/bench-multi.mjs`，用 5 张图
覆盖不同失败模式，共 **38 个可独立核对的图上事实**：

| 图 | 考的是什么 | 事实数 |
|---|---|---|
| dashboard.png | 密集仪表盘 + 彩色告警行 | 12 |
| probe-smalltext.png | 15px 小字单据 | 7 |
| t_table.png | 中文表格 | 6 |
| t_chart.png | 柱状图标签与数值 | 6 |
| t_code.png | 等宽代码截图 | 7 |

图片与标准答案由 `tools/make-bench-images.py` 一起生成，基准不会和实际图漂移。
（坑：Arial 没有中文字形，中文会渲染成方块，必须用 `msyh.ttc`。）

### 关键发现：不要把 `-ngl` 写死

llama.cpp 自带显存自适应，日志里早就写着：

```
common_fit_params: failed to fit params to free device memory: n_gpu_layers already set by user to 99, abort
```

`-ngl 99` 把它的自适应顶掉了。改成 `--fit on --fit-target N`（N = 想留多少 MiB 空闲），
由它自己决定摊几层到 GPU。扫描结果（mmproj 在 CPU）：

| fit-target | 得分 | 耗时 | 空闲显存 |
|---|---|---|---|
| 128 | 12/12 | 19.5 s | 465 MB |
| 512 | 12/12 | 20.5 s | 824 MB |
| **1024** | 12/12 | 22.5 s | **1362 MB** |
| 2048 | 12/12 | 26.4 s | 2338 MB |

**多花 3 秒换 2.3 GB 余量。** 取 1024。

### 再把 mmproj 挪回 GPU

图片编码慢是因为 797 MB 的视觉投影器在 CPU 上跑。有了余量后去掉 `--no-mmproj-offload`，
`--fit` 会自动少摊几层来补偿，于是**又快又不吃显存**：

| 配置 | 平均耗时 | 空闲显存 |
|---|---|---|
| `-ngl 99` + mmproj CPU | 15.8 s/图 | 137 MB |
| `--fit 1024` + mmproj CPU | 16.2 s/图 | 1362 MB |
| **`--fit 1024` + mmproj GPU** | **12.0 s/图** | **1266 MB** |

### 两档模型对比（同一套 5 图基准）

| 档位 | 模型 | 命中 | 平均耗时 | 空闲显存 |
|---|---|---|---|---|
| **precise（默认）** | Qwen3-VL-4B Q4_K_M | **38/38** | 12.0 s | 1266 MB |
| fast | Qwen3-VL-2B Q4_K_M | 36/38 | **5.0 s** | 1257 MB |

2B 快 2.4 倍，但会漏标题和一个代码标识符。默认用 precise，需要速度时切换：

```
gateway-control.cmd vlm             列出两档和当前档位
gateway-control.cmd vlm fast        切到 2B，立即卸载当前模型
gateway-control.cmd vlm precise     切回 4B
gateway-control.cmd bench           用当前档位跑一遍 5 图基准
```

路由 id 已改为 `local-vl`（不再绑定具体权重），**换模型不需要重启 DSH**。

## 附三：2026-10-17 第四轮优化（10 图基准 + 并发槽位）

### 基准扩到 10 张，含 5 张刁钻的

简单组 5 张已经全对，说明基准太软。新增（`tools/make-bench-hard.py`）：

| 图 | 考点 |
|---|---|
| h_dense.png | 14px 密集中文标签面板 |
| h_rotated.png | 整图倾斜 6° |
| h_lowcontrast.png | #B2B2B2 浅灰字压白底 |
| h_longtable.png | 8 行 × 3 列长表 |
| h_line.png | 折线图 + 图例 + 三档纵轴刻度 |

**Qwen3-VL-4B：64/64 全中，0 虚构，平均 10.1 秒/图。** 倾斜、低对比度、长表、折线图全对。

> 题库坑：`h_dense` 第一版问题只问"每一项的名字和值"，模型如实照做没读标题，
> 被我记成漏项。问题改成"读出标题以及每一项"后满分。**基准的问题措辞本身也要复核。**

### 并发槽位：-np 2 是最优

DSH 会同时派多个子代理。`-np 1` 时第二个请求排队：

| -np | 并发 3 张总耗时 | 相对串行加速 | 空闲显存 |
|---|---|---|---|
| 1 | 22.6 s | 1.20× | 1276 MB |
| **2（采用）** | **16.3 s** | **1.67×** | **1278 MB** |
| 3 | 18.4 s | 1.52× | 1265 MB |
| 4 | 18.2 s | 1.53× | 1261 MB |

4 GB 卡在 2 路就饱和，再多的槽位只是把上下文切碎。`-np 2` 时每槽 8192 上下文，
而剥离系统提示后单次请求只有 600 token 左右，够用。

### 磁盘清理

删除未使用的 `qwen2.5-vl-3b`（3.04 GB）和 `qwen3-vl-4b-q3`（1.93 GB），
保留 `qwen3-vl-4b`（precise）与 `qwen3-vl-2b`（fast）。

### 当前最终参数

```
-c 16384 -np 2 -b 1024 -ub 256 -fa on
--cache-type-k q8_0 --cache-type-v q8_0
--image-min-tokens 512 --fit on --fit-target 1024
```

加载后约 2.7 GB 占用 / **1.27 GB 空闲**；卸载后回到 311 MB / 3.65 GB 空闲。

## 卸载

1. 删掉启动文件夹里的 `DSH Local LLM Gateway.lnk`。
2. 删掉 `cordis.patch.yml` 末尾从 `# --- Local GGUF model` 开始的两块。
3. 重启 DSH，然后可以整个删掉 `dsh-local-llm` 文件夹。
