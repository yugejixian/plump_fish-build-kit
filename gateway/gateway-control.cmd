@echo off
setlocal
rem Control for the DSH local GGUF gateway (see README.md in this folder).
rem   gateway-control.cmd start            start the gateway if it is not running
rem   gateway-control.cmd stop             unload the model and stop the gateway
rem   gateway-control.cmd status           gateway + model state, as JSON
rem   gateway-control.cmd unload           free VRAM now, keep the gateway up
rem   gateway-control.cmd logs             tail the gateway log
rem   gateway-control.cmd vlm              list model profiles and the active one
rem   gateway-control.cmd vlm precise      Qwen3-VL-4B: 38/38 facts, ~12 s/image
rem   gateway-control.cmd vlm fast         Qwen3-VL-2B: 36/38 facts, ~5 s/image
rem   gateway-control.cmd bench            score the active model on 5 images

set "HERE=%~dp0"
set "HERE=%HERE:~0,-1%"
set "GW=http://127.0.0.1:8099"
set "NODE=%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe"

if /i "%1"=="start"  goto :start
if /i "%1"=="stop"   goto :stop
if /i "%1"=="status" goto :status
if /i "%1"=="unload" goto :unload
if /i "%1"=="logs"   goto :logs
if /i "%1"=="vlm"    goto :vlm
if /i "%1"=="bench"  goto :bench
echo usage: %~nx0 {start^|stop^|status^|unload^|logs^|vlm [precise^|fast]^|bench}
exit /b 1

:vlm
if "%2"=="" (
  "%NODE%" "%HERE%\tools\switch-model.mjs" list
) else (
  "%NODE%" "%HERE%\tools\switch-model.mjs" %2
)
exit /b 0

:bench
"%NODE%" "%HERE%\tools\bench-multi.mjs"
exit /b 0

:start
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Invoke-RestMethod -Uri '%GW%/gateway/status' -TimeoutSec 2 | Out-Null; Write-Host 'gateway already running' } catch { Start-Process -FilePath 'wscript.exe' -ArgumentList '\"%HERE%\launch-gateway.vbs\"' -WindowStyle Hidden; Start-Sleep -Seconds 2; Write-Host 'gateway started' }"
exit /b 0

:stop
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Invoke-RestMethod -Method Post -Uri '%GW%/gateway/unload' -TimeoutSec 30 | Out-Null; Write-Host 'model unloaded' } catch { Write-Host 'gateway not reachable (already stopped?)' }; Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | Where-Object { $_.CommandLine -like '*gateway.js*' } | ForEach-Object { Write-Host ('stopping gateway pid ' + $_.ProcessId); Stop-Process -Id $_.ProcessId -Force }"
exit /b 0

:status
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Invoke-RestMethod -Uri '%GW%/gateway/status' -TimeoutSec 3 | ConvertTo-Json -Depth 6 } catch { Write-Host 'gateway is not running' }"
exit /b 0

:unload
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Invoke-RestMethod -Method Post -Uri '%GW%/gateway/unload' -TimeoutSec 30 | ConvertTo-Json -Depth 5 } catch { Write-Host 'gateway is not running' }"
exit /b 0

:logs
powershell -NoProfile -Command "Get-Content '%HERE%\logs\gateway.log' -Tail 40 -Wait"
exit /b 0
