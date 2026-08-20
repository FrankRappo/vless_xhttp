@echo off
setlocal
cd /d "%~dp0"

if not exist "%~dp0xray.exe" (
  echo ERROR: put xray.exe in this directory.
  exit /b 1
)

"%~dp0xray.exe" run -test -c "%~dp0xray-windows-178-104-149.json"
if errorlevel 1 exit /b %errorlevel%

echo SOCKS5: 127.0.0.1:20849
echo HTTP:   127.0.0.1:20850
echo Close this window to stop only this Xray instance.
"%~dp0xray.exe" run -c "%~dp0xray-windows-178-104-149.json"
