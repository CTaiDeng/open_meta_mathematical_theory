@echo off
REM Copyright (C) 2025 GaoZheng
REM SPDX-License-Identifier: GPL-3.0-only
REM This file is part of this project.
REM Licensed under the GNU General Public License version 3.
REM See https://www.gnu.org/licenses/gpl-3.0.html for details.

setlocal EnableExtensions EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "REPO_ROOT=%%~fI"
set "TOOL=%SCRIPT_DIR%normalize_full_reference_style.ps1"
set "ROOT=%REPO_ROOT%\src\full_reference"

if not exist "%TOOL%" (
  echo [error] Missing tool: %TOOL%
  exit /b 1
)
if not exist "%ROOT%" (
  echo [error] Missing root directory: %ROOT%
  exit /b 1
)

REM Prefer PowerShell Core (pwsh); fallback to Windows PowerShell
where pwsh >NUL 2>&1
if %ERRORLEVEL%==0 (
  pwsh -NoLogo -File "%TOOL%" -Root "%ROOT%" %*
) else (
  powershell -NoLogo -ExecutionPolicy Bypass -File "%TOOL%" -Root "%ROOT%" %*
)

endlocal
