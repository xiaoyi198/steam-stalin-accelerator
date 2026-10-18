@echo off
chcp 65001 >nul
cd /d "%~dp0"
setlocal EnableExtensions

rem ============================================================
rem  Steam 节点优选 —— 一键部署 / 一键卸载 / 查看状态
rem
rem  部署：双击本文件即可。全程只弹一次 UAC，之后全部静默自动运行。
rem  卸载：在命令行里执行  本文件 /uninstall
rem  状态：在命令行里执行  本文件 /status    （不需要管理员）
rem ============================================================

set "MODE=install"
if /I "%~1"=="/uninstall" set "MODE=uninstall"
if /I "%~1"=="/u"         set "MODE=uninstall"
if /I "%~1"=="/remove"    set "MODE=uninstall"
if /I "%~1"=="/status"    set "MODE=status"
if /I "%~1"=="/s"         set "MODE=status"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SRC=%~dp0steam-node-picker.ps1"
set "INST=%ProgramData%\SteamNodePicker\steam-node-picker.ps1"

rem 已经装过的话优先用 %ProgramData% 里那份，避免 F: 盘改盘符/被拔后行为不一致
if exist "%INST%" set "SRC=%INST%"

rem ---- 状态查询不需要提权，直接看 ----
if "%MODE%"=="status" (
    if not exist "%SRC%" (
        echo.
        echo   [错误] 找不到 steam-node-picker.ps1
        echo   请把本文件和 steam-node-picker.ps1 放在同一个文件夹里。
        echo.
        pause
        exit /b 1
    )
    "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SRC%" -Status
    pause
    exit /b 0
)

rem ---- 提权（整个流程只在这里弹一次 UAC）----
rem S-1-16-12288 = High Mandatory Level（已提权）
whoami /groups | findstr /C:"S-1-16-12288" >nul
if errorlevel 1 (
    echo.
    echo   需要管理员权限。正在弹出 UAC ...
    echo   ^>^>^>  点一次「是」就行，后面全程不用再授权。
    echo.
    if "%MODE%"=="uninstall" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '/uninstall' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    )
    exit /b
)

if not exist "%SRC%" (
    echo.
    echo   [错误] 同目录下找不到 steam-node-picker.ps1
    echo   请把两个文件放在同一个文件夹里再运行。
    echo.
    pause
    exit /b 1
)

if "%MODE%"=="uninstall" goto :UNINSTALL

echo.
echo ============================================================
echo    Steam 节点优选 —— 部署（这就是唯一一次授权）
echo ============================================================
echo.
echo [1/4] 注册计划任务：开机守护 / 每 30 分刷新 / 常驻自动拉黑
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SRC%" -InstallAuto
if exist "%INST%" set "SRC=%INST%"

echo.
echo [2/4] 立刻跑一次扫描，把已知慢节点先打进 hosts 黑洞
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SRC%" -ApplyBlock

echo.
echo [3/4] 立刻启动值守进程（不用等下次开机）
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SRC%" -KickWatch

echo.
echo [4/4] 检查落地情况
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SRC%" -Status

echo.
echo ============================================================
echo    全部完成 —— 以后零操作、零弹窗：
echo      下载中   值守自动发现慢节点并拉黑，Steam 自动换线
echo      每 30 分 自动重算黑名单，已恢复的节点会被放出来
echo      开机     自动恢复守护，不需要你再点任何东西
echo.
echo    看了想改主意：
echo      %~nx0 /status        看现在的状态（不需要管理员）
echo      %~nx0 /uninstall     全部还原（同样只弹一次 UAC）
echo ============================================================
echo.
echo    值守日志：%LOCALAPPDATA%\SteamNodePicker\watch.log
echo    实时盯屏：powershell -NoProfile -Command "Get-Content -Wait '%LOCALAPPDATA%\SteamNodePicker\watch.log'"
echo.
pause
exit /b 0

:UNINSTALL
echo.
echo ============================================================
echo    Steam 节点优选 —— 卸载（同样只弹一次 UAC）
echo ============================================================
echo.
echo [1/3] 停掉并删除计划任务
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SRC%" -RemoveAuto

echo.
echo [2/3] 还原 hosts 到被修改前的样子
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SRC%" -Undo

echo.
echo [3/3] 复查残留
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SRC%" -Status

echo.
echo    完成。想再确认一次就跑一次 %~nx0 /status
echo.
pause
exit /b 0
