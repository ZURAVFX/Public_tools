@echo off
setlocal
title AgentPort NInfer RTX 4080 Setup
cd /d "%~dp0"
echo.
echo =============================================================
echo   AgentPort NInfer setup for RTX 4080 / 4080 SUPER 16 GB
echo =============================================================
echo.
echo This setup checks WSL, offers to install Ubuntu-24.04 if missing,
echo builds the sm_89 NInfer engine, and downloads the Qwen3.8 min-Q4
echo NInfer artifact.
echo.
echo Expect a large download: CUDA toolkit plus about 13 GB of model data.
echo.
choice /C YN /N /M "Continue with NInfer installation? [Y/N] "
if errorlevel 2 exit /b 0
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Bootstrap-NInfer4080.ps1"
if errorlevel 1 (
  echo.
  echo NInfer setup is not complete yet. Read the message above.
  echo If Windows installed WSL/Ubuntu just now, reboot if requested and
  echo launch Ubuntu-24.04 once to complete its first-run username/password
  echo setup. Then run this file again.
  echo.
  pause
  exit /b 1
)
echo.
echo NInfer setup complete and AgentPort backend preference is set to Auto.
echo.
pause
exit /b 0
