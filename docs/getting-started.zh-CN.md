# SteadyAgent 2 快速开始

SteadyAgent 2 只支持 Windows 上的 Codex Desktop。

## 1. 验证 checkout

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

## 2. 预览

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1
```

默认是 dry-run，不写文件。

## 3. 应用

全新安装：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply
```

替换已有工作流：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply -ReplaceExistingWorkflow
```

写入默认 `%ProgramData%\OpenAI\Codex\requirements.toml` 时使用管理员 PowerShell。

## 4. 重启并诊断

重启 Codex Desktop 后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\diagnose-install.ps1" -RequireHooksActive
```

文件已安装或脚本 smoke 通过，不代表旧 Codex 任务已经加载新 managed Hooks。必须重启任务并取得 `fail=0`。

## 5. 必要时回滚

使用安装器输出的收据路径。先预览，再加 `-Apply`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\rollback.ps1" -ReceiptPath "<备份目录>\migration-receipt.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\rollback.ps1" -ReceiptPath "<备份目录>\migration-receipt.json" -Apply
```

若已安装文件、已移除 V1 路径、快照或 Git Hook 路径发生漂移，回滚器会在写入前停止。
