@echo off
echo Installing dotnet-ildasm tool...

REM Check if dotnet CLI is available
where dotnet >nul 2>nul
if errorlevel 1 (
    echo [ERROR] dotnet CLI not found. Please install the .NET SDK first.
    pause
    exit /b 1
)

REM Attempt to install dotnet-ildasm
dotnet tool install --global dotnet-ildasm
if errorlevel 1 (
    echo.
    echo [ERROR] Failed to install dotnet-ildasm. Check if the .NET SDK is installed.
    pause
    exit /b 1
)

REM Confirm command exists
where dotnet-ildasm >nul 2>nul
if errorlevel 1 (
    echo.
    echo [ERROR] dotnet-ildasm was not found in PATH. Try restarting your terminal.
    pause
    exit /b 1
)

echo.
dotnet-ildasm --version

echo.
echo [SUCCESS] dotnet-ildasm installed and ready to use.
pause
