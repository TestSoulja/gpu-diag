@echo off
title GPU / display diagnostics
chcp 65001 >nul 2>&1
cd /d "%~dp0"

if not exist "%~dp0GPU-Diag.ps1" (
  echo.
  echo  GPU-Diag.ps1 is not next to this file.
  echo  Extract the whole ZIP into a normal folder first, then run this file again.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0GPU-Diag.ps1" %*

if errorlevel 1 pause
