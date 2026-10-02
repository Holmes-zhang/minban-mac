@echo off
setlocal
set "MBM_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "MBM_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%MBM_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Launcher.ps1" -Mode Import
echo.
pause
endlocal
