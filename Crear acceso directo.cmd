@echo off
title Limpiador de USB - crear acceso directo
cd /d "%~dp0"

rem El trabajo esta en el .ps1 de al lado. Meter PowerShell multilinea
rem dentro de un .cmd no funciona: el ^ pierde su valor dentro de las
rem comillas y la orden se parte por la mitad.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Crear acceso directo.ps1"

pause
