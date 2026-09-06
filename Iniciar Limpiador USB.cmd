@echo off
title Limpiador de USB
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% equ 0 goto :run

echo.
echo   Solicitando permisos de administrador...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Limpiador-USB.ps1"
if %errorlevel% neq 0 (
  echo.
  echo   El programa termino con errores. Codigo: %errorlevel%
  pause
)
exit /b
