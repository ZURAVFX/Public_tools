@echo off
setlocal
title AgentPort RTX 4080 Full Benchmark v2
cd /d "%~dp0"
echo.
echo =============================================================
echo   AgentPort RTX 4080 FULL benchmark v2
echo =============================================================
echo.
echo This benchmark requires NInfer so it can compare TextGen against the
echo RTX 4080 NInfer backend. It will not silently skip NInfer.
echo.
wsl.exe -d Ubuntu-24.04 -- bash -lc "test -x ~/.agentport/ninfer-src/build-sm89/apps/ninfer-serve -a -s ~/.agentport/models/qwen3_8_27b_minq4.ninfer" >nul 2>nul
if errorlevel 1 (
  echo NInfer RTX 4080 is not ready yet.
  echo.
  choice /C YN /N /M "Run NInfer setup now? [Y/N] "
  if errorlevel 2 (
    echo.
    echo Full benchmark cancelled. Install NInfer first, then run this again.
    pause
    exit /b 2
  )
  call "%~dp0Install-NInfer4080.cmd"
  if errorlevel 1 (
    echo.
    echo NInfer is still not ready, so the benchmark will NOT start.
    pause
    exit /b 3
  )
)

wsl.exe -d Ubuntu-24.04 -- bash -lc "test -x ~/.agentport/ninfer-src/build-sm89/apps/ninfer-serve -a -s ~/.agentport/models/qwen3_8_27b_minq4.ninfer" >nul 2>nul
if errorlevel 1 (
  echo NInfer readiness check still failed. Benchmark cancelled.
  pause
  exit /b 4
)

echo.
echo Starting benchmark v2.
echo TextGen is standardised to 49k context, q4_0 KV, gpu-layers -1,
echo fit-target 768 MiB, parallel 1, and no mmproj during text-only tests.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Benchmark-AgentPortMatrix-v2.ps1"
set EXITCODE=%ERRORLEVEL%
echo.
if not "%EXITCODE%"=="0" echo Benchmark exited with code %EXITCODE%.
echo Copy the final v2 results table back into ChatGPT for analysis.
echo.
echo Press any key to close this window.
pause >nul
exit /b %EXITCODE%
