@echo off
setlocal
rem ============================================================
rem  桌面宠物 —— 双击入口
rem
rem  这个窗口只是「启动器」:真正的宠物和托盘图标跑在后台隐藏进程里,
rem  关掉这个窗口不会把宠物一起关掉。要退出请右键右下角「宠」图标 -> 退出。
rem
rem  用法:
rem    start.bat                 启动(托盘 + 桌宠)
rem    start.bat -Mode pet       只跑宠物并占着这个窗口(调试用)
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

rem 没有参数 = 正常启动:本体转后台,这个窗口只显示提示
if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SELF%" -Mode launch
    echo  ------------------------------------------------------------
    echo   现在可以关掉这个窗口,宠物会继续待在托盘里。
    echo   退出请右键右下角「宠」图标 -^> 退出。
    echo  ------------------------------------------------------------
    pause
    exit /b 0
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SELF%" %*
if errorlevel 1 (
    echo.
    echo [提示] 退出码 %errorlevel%,详情看 pet.log
    pause
)