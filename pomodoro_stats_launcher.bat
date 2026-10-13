@echo off
rem ===========================================================
rem  Catime Pomodoro Stats Plugin - launcher
rem
rem  Why this file exists:
rem  Catime starts a .ps1 plugin by running "powershell.exe ..."
rem  and relies on the PATH environment variable to find it.
rem  On some systems the PATH does not contain
rem    %SystemRoot%\System32\WindowsPowerShell\v1.0
rem  so Catime reports "powershell.exe not found" and the plugin
rem  never runs. cmd.exe always lives in System32, so this .bat
rem  launcher is always found, and it calls PowerShell by its
rem  absolute path instead of relying on PATH.
rem ===========================================================

setlocal

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" (
    echo powershell.exe not found
    exit /b 1
)

rem Run the real logic script that sits next to this launcher.
rem Catime displays the output.txt written by that script.
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0pomodoro_stats_core.ps1"

endlocal
