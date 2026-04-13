@echo off
setlocal

:: ============================================================
::  WSL Sleep Manager - Launcher
::  Place this .bat next to:
::    Install-WSLSleepManager.ps1
::    Install-TmuxResurrect.ps1
:: ============================================================

title WSL Sleep Manager

:MENU
cls
echo.
echo  ==========================================
echo   WSL Sleep Manager
echo  ==========================================
echo.
echo   1  Install / Reinstall
echo   2  Uninstall
echo   3  View log
echo   4  Install tmux-resurrect in a distro
echo   0  Exit
echo.
set /p CHOICE="  Choose an option: "

if "%CHOICE%"=="1" goto INSTALL
if "%CHOICE%"=="2" goto UNINSTALL
if "%CHOICE%"=="3" goto VIEWLOG
if "%CHOICE%"=="4" goto TMUX
if "%CHOICE%"=="0" goto END
goto MENU

:: ------------------------------------------------------------
:INSTALL
cls
echo  Installing WSL Sleep Manager...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-WSLSleepManager.ps1"
echo.
pause
goto MENU

:: ------------------------------------------------------------
:UNINSTALL
cls
echo  Uninstalling WSL Sleep Manager...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-WSLSleepManager.ps1" -Uninstall
echo.
pause
goto MENU

:: ------------------------------------------------------------
:VIEWLOG
cls
set LOG=%ProgramData%\WSLSleepManager\wsl-sleep-manager.log
if exist "%LOG%" (
    type "%LOG%"
) else (
    echo  Log file not found: %LOG%
    echo  The manager has not been installed yet.
)
echo.
pause
goto MENU

:: ------------------------------------------------------------
:TMUX
cls
echo  Install tmux-resurrect in a WSL distro
echo.
if not exist "%~dp0Install-TmuxResurrect.ps1" (
    echo  ERROR: Install-TmuxResurrect.ps1 not found next to this .bat file.
    echo  Make sure all three files are in the same folder.
    echo.
    pause
    goto MENU
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-TmuxResurrect.ps1"
goto MENU

:: ------------------------------------------------------------
:END
endlocal
exit /b 0
