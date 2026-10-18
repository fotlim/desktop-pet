@echo off
setlocal
rem ============================================================
rem  桌面宠物 —— 双击入口
rem
rem  用法:
rem    start.bat                 托盘 + 宠物
rem    start.bat -Mode pet       只跑宠物(不要托盘)
rem    start.bat -Mode install   装开机自启
rem    start.bat -Mode list      看有哪些模型
rem ============================================================

set "SELF=%~dp0DesktopPet.ps1"

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo [错误] 找不到 powershell.exe
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SELF%" %*
if errorlevel 1 (
    echo.
    echo [提示] 退出码 %errorlevel%,详情看 pet.log
    if "%~1"=="" pause
)
