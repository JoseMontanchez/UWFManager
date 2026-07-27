@echo off
setlocal EnableExtensions
title UWF Aulas

set "PS1=%~dp0UWF-Aulas.ps1"

if not exist "%PS1%" (
    echo No se encuentra UWF-Aulas.ps1 junto a este archivo.
    pause
    exit /b 1
)

net session >nul 2>&1
if errorlevel 1 (
    echo Solicitando privilegios de administrador...
    powershell -NoProfile -Command "Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('\"'+$env:PS1+'\"') -Verb RunAs"
    exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%PS1%"
exit /b %ERRORLEVEL%
