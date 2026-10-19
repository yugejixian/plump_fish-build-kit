# 开发者文档

## 架构

```
新手向大肥鱼build整合.exe (C# WinForms, src/Starter.cs)
        │  调用 (powershell -File)
        ▼
install.ps1 ── 探测硬件 → 验包 → 复制 → 写配置 → 装插件 → 补依赖 → 自检
        │
        ├─► gateway/config.json        (端口、模型、白名单)
        ├─► gateway/launch-gateway.vbs (开机自启 + 隐藏窗口)
        └─► %USERPROFILE%\.dsh\
                ├─ profiles\desktop\cordis.patch.yml  (provider + 工具开关)
                ├─ profiles\desktop\AGENTS.md         (调用规则块)
                ├─ AGENTS.md                          (同一份规则)
                └─ profiles\desktop\node_modules\     (插件 + 宿主依赖)

运行期：
DSH ──openai-completions──► gateway.js :8099 ──► llama-server.exe :18080
                                   │
                                   ├─ autoAttachImages   提示词里出现图片路径就附加(≤8 张)
                                   ├─ inlineFiles        [[file:...]] 文本内联(白名单三根)
                                   └─ saveDirective      [[save:...]] 结果落盘,只回收据
```

## 目录

| 路径 | 作用 |
|---|---|
| `install.ps1` | 主安装器，10 个阶段（环境/硬件/验包/复制/配置/规则/插件/依赖/自检/单副本） |
| `uninstall.ps1` | 卸载；按 `.dsh-local-llm-state.json` 只删自己创建的东西 |
| `verify.ps1` | 四层校验：完整性、清单、上游哈希、行为静态检查 |
| `smoke.ps1` | 装完体检：路由是否存在、`/v1/models` 名字、近期有没有"大 prompt"真实流量 |
| `pack.ps1` | 从 `payload/` 重建 `manifest.json`（payload 是唯一真源） |
| `gateway/gateway.js` | OpenAI 兼容网关；起停 llama-server、图片附加、内联、存盘 |
| `gateway/rules/AGENTS.block.md` | 写进 DSH 的调用规则（**改这里，不要改生成的 AGENTS.md**） |
| `src/Starter.cs` | 图形界面：一键安装/卸载/校验/看文档/取消 |

## 构建 GUI

```powershell
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" `
  /target:winexe /optimize+ /out:新手向大肥鱼build整合.exe `
  /r:System.Windows.Forms.dll /r:System.Drawing.dll src\Starter.cs
```

## 打包安装包（不发布 payload 时）

`pack.ps1` 以 `payload/` 为唯一真源重建清单：

```powershell
.\pack.ps1 -Apply -PackageDir .            # 全量重算 SHA256
.\pack.ps1 -Apply -Only gateway            # 只重算 gateway/（其它条目沿用）
.\pack.ps1 -OutDir D:\clone -PackageDir .  # 克隆一份
```

> 注意：`-Only` 会保留未重算的旧条目。**删掉 payload 里的文件后必须全量重算**，
> 否则 `verify.ps1` 会报缺失、安装器会拒装。

## 测试

```powershell
.\tests\run-ab.ps1    # 配置块 fuzz
.\tests\run-cg.ps1    # 还原/足迹/卸载/打包/路径
.\tests\run-h.ps1     # 运行时剪枝
.\tests\run-i.ps1     # 增量安全：不覆盖用户已有文件
.\tests\run-j.ps1     # 插件版本策略：新版保留、旧版升级
.\tests\run-k.ps1     # 卸载只删自己创建的
.\tests\run-e.ps1     # 无 GPU 回退
```

全部在 `D:\_test` 下的隔离沙箱跑，用假的 `USERPROFILE`，不碰真实 `~\.dsh`。

## PowerShell 5.1 的坑（都踩过）

- `.ps1` 带中文必须 **UTF-8 带 BOM**，否则被当 ANSI 撕碎
- 没有 `??` 运算符（那是 PS7）
- **变量名不分大小写**：`$t` 和 `$T` 是同一个变量（曾把我坑进死循环）
- here-string `@'...'@` **不带结尾换行**，拼 YAML 会粘行
- 字符串里带 `{` 的正则要小心，`'\{\{'` 可能让解析器以为开始代码块
- `R`、`W` 这类单字母函数名会被内置别名顶掉（`R` = `Invoke-History`）

## 设计约束

1. **增量优先**：任何写操作都不许覆盖用户已有内容；升级前先备份
2. **卸载可审计**：只有状态文件里记录的才删
3. **白名单**：网关的 `[[file:]]`/`[[save:]]` 只认三个根（安装目录、它的 `work`、`D:\工作区`）
4. **不联网**：安装期不联网；`verify.ps1 -CheckUpstream` 是显式的可选项