@echo off
setlocal

:: Define folder paths (customize if needed)
set OLD_DIR=D:\Old
set NEW_DIR=D:\New

:: Option: Include same files in report ($true/$false)
set INCLUDE_SAME=$false

:: Locate script path
set SCRIPT_DIR=%~dp0
set PS_SCRIPT=%SCRIPT_DIR%Compare-Folders.ps1

:: Run PowerShell script with arguments
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%PS_SCRIPT%' -Old '%OLD_DIR%' -New '%NEW_DIR%' -IncludeSame %INCLUDE_SAME%"

pause
