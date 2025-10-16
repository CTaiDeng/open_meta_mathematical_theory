@echo off
REM Copyright (C) 2025 GaoZheng
REM SPDX-License-Identifier: GPL-3.0-only
REM This file is part of this project.
REM Licensed under the GNU General Public License version 3.
REM See https://www.gnu.org/licenses/gpl-3.0.html for details.

setlocal EnableExtensions EnableDelayedExpansion
set SCRIPT_DIR=%~dp0
set REPO_ROOT=%SCRIPT_DIR%..
set TOOL=%SCRIPT_DIR%sync_full_reference_symlinks.ps1
set CFG=%REPO_ROOT%src\full_reference\Link.json

if not exist "%TOOL%" (
  echo [error] Missing tool: %TOOL%
  exit /b 1
)
if not exist "%CFG%" (
  echo [error] Missing config: %CFG%
  exit /b 1
)

where pwsh >NUL 2>&1
if %ERRORLEVEL%==0 (
  pwsh -NoLogo -File "%TOOL%" -Config "%CFG%" %*
) else (
  powershell -NoLogo -ExecutionPolicy Bypass -File "%TOOL%" -Config "%CFG%" %*
)

endlocal
