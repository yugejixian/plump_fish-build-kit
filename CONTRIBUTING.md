# 贡献指南

欢迎 issue 和 PR。请先读 `docs/DEVELOPMENT.md` 里的"设计约束"和"PowerShell 5.1 的坑"。

## 提交前自查

```powershell
# 1. 语法
powershell -NoProfile -Command "Get-ChildItem *.ps1 | ForEach-Object { \$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile(\$_.FullName,[ref]\$null,[ref]\$e); if (\$e) { \$_.Name + ': ' + \$e[0].Message } }"

# 2. 跑测试（在隔离沙箱里，不会碰你的真实 ~\.dsh）
.\tests\run-i.ps1
.\tests\run-k.ps1

# 3. 确认没有提交敏感内容
git diff --cached | Select-String -Pattern 'C:\\Users\\|token|password|\.dsh\\profiles'
```

## 绝对不要提交

- `payload/`（模型、运行时、提取出来的依赖）
- `manifest.json`（由 `pack.ps1` 生成）
- 任何 `*.exe` / `*.zip`
- 你自己的 `user-settings/`、`~/.dsh` 快照、日志
- 任何密钥、Token、Cookie

`.gitignore` 已经挡了大部分，但**不要依赖它**。

## 代码约定

- 注释用英文，界面文案用中文（面向小白）
- 破坏性代码必须在 `-Apply` **和**显式开关双重保护之内
- 新增删除逻辑，必须同时在 `tests/run-k.ps1` 里加一条"不误删"的断言
- 改 `gateway/rules/AGENTS.block.md` 后，README 与文档里的示例命令要同步

## PR 描述请包含

1. 现象/动机
2. 改了什么（文件 + 行为）
3. 怎么验证的（贴输出，尤其是 `verify.ps1` 和测试结果）
4. 有没有动到卸载/删除逻辑（有的话重点说明）