# 隐私说明

## 一句话

**不收集任何遥测。没有账号、没有上报、没有云端中转。** 所有推理都在你自己的机器上。

## 数据都去哪儿了

| 数据 | 位置 | 会不会离开本机 |
|---|---|---|
| 你发的图片与文字 | 直接进入本机 `llama-server` | **不会** |
| 模型输出 | 网关返回给 DSH；用 `[[save:]]` 时写到白名单目录 | **不会** |
| 网关日志 | `<安装目录>\logs\gateway.log`（滚动，默认 5 MB） | 不会，除非你自己拷走 |
| 推理日志 | `<安装目录>\logs\llama-server.log` | 同上 |
| 安装状态 | `%USERPROFILE%\.dsh\profiles\desktop\.dsh-local-llm-state.json` | 不会 |
| 卸载备份 | `<文件>.dsh-llm.bak` / `.orig.bak` | 不会 |

## 唯一的联网行为

`verify.ps1 -CheckUpstream` —— 你**显式**加了这个开关才会去 GitHub / ModelScope
比对上游哈希。不加就完全不联网。

## 本仓库里没有你的隐私

开源的是源码。以下内容**从不进仓库**（`.gitignore` 已挡）：

- `payload/`：包含从你本机 DSH 里提取的依赖
- `user-settings/`：你的个人 DSH 配置快照（早期版本里还带过主机名，已删）
- `manifest.json`：你本机文件的路径与哈希
- 日志、`.bak`、安装状态文件

## 删除你的数据

```powershell
.\uninstall.ps1 -Apply -TargetDir "D:\DSH-LocalLLM" -RemovePlugins
```

这会删掉安装目录、配置块、规则块、自启项，以及本包自带的插件；
你的 `node_modules` 公共依赖与 DSH 自身不动（这是为了不弄坏别的插件）。