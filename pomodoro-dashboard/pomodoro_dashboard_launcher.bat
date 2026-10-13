@echo off
rem ===========================================================
rem  Catime Pomodoro Dashboard Plugin - launcher
rem
rem  Why a .bat: Catime starts .ps1 plugins by running
rem  "powershell.exe" found via PATH. On machines where PATH
rem  does not include %SystemRoot%\System32\WindowsPowerShell\v1.0
rem  Catime reports "powershell.exe not found" and the plugin
rem  never runs. cmd.exe always lives in System32, so this .bat
rem  launcher is always found, and it calls PowerShell by its
rem  absolute path. -STA is required by the WPF dashboard UI.
rem ===========================================================

setlocal

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" (
    echo powershell.exe not found
    exit /b 1
)

rem Run the dashboard UI script that sits next to this launcher.
rem It reads pomodoro_stats.json from the plugins root (one level up).
"%PSEXE%" -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "%~dp0pomodoro_dashboard_core.ps1"

endlocal
