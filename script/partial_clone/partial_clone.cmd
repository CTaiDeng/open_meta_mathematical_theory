@echo off
REM SPDX-License-Identifier: GPL-3.0-only
REM Copyright (C) 2025 GaoZheng

setlocal ENABLEDELAYEDEXPANSION
set "_SCRIPT=%~dp0partial_clone.ps1"

if not exist "%_SCRIPT%" (
  echo [partial-clone] PowerShell script not found: %_SCRIPT%
  exit /b 1
)

REM prefer pwsh, fallback to powershell
where pwsh >nul 2>nul
if not errorlevel 1 (
  set "PWSH=pwsh"
) else (
  where powershell >nul 2>nul
  if errorlevel 1 (
    echo [partial-clone] PowerShell not found (pwsh or powershell)
    exit /b 1
  )
  set "PWSH=powershell"
)

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%_SCRIPT%" %*
exit /b %ERRORLEVEL%
