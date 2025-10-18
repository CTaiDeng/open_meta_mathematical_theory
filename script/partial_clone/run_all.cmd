@echo off
REM SPDX-License-Identifier: GPL-3.0-only
REM Copyright (C) 2025 GaoZheng

setlocal ENABLEDELAYEDEXPANSION
set "_DIR=%~dp0"
set "_PS1=%_DIR%run_all.ps1"

if not exist "%_PS1%" (
  echo [batch-partial-clone] PowerShell script not found: %_PS1%
  exit /b 1
)

REM Prefer pwsh, fallback to Windows PowerShell
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  set "PWSH=pwsh"
) else (
  where powershell >nul 2>nul
  if errorlevel 1 (
    echo [batch-partial-clone] PowerShell not found (pwsh or powershell)
    exit /b 1
  )
  set "PWSH=powershell"
)

REM Light color header (ANSI, best-effort)
for /f "delims=" %%A in ('echo prompt $E ^| cmd') do set "ESC=%%A"
echo %ESC%[36m[batch-partial-clone]%ESC%[0m starting...

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%_PS1%" %*
set "RC=%ERRORLEVEL%"

if "%RC%"=="0" (
  echo %ESC%[32m[batch-partial-clone] done%ESC%[0m
) else (
  echo %ESC%[31m[batch-partial-clone] done with errors (rc=%RC%)%ESC%[0m
)

exit /b %RC%

