@echo off
setlocal EnableExtensions
title UWF Aulas

set "PY=%~dp0UWF-Aulas.py"

if not exist "%PY%" (
    echo No se encuentra UWF-Aulas.py junto a este archivo.
    pause
    exit /b 1
)

net session >nul 2>&1
if errorlevel 1 (
    echo Solicitando privilegios de administrador...
    powershell -NoProfile -Command "Start-Process python.exe -ArgumentList ('\"'+$env:PY+'\"') -Verb RunAs"
    exit /b 0
)

python "%PY%"
exit /b %ERRORLEVEL%
