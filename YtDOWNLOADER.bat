@echo off
chcp 65001 >nul
setlocal EnableExtensions

set "APPDIR=%~dp0"
set "PS1=%APPDIR%YtDOWNLOADER.ps1"
set "ERRLOG=%APPDIR%YtDOWNLOADER_error.log"

title YtDOWNLOADER by OsageP - Version 1.0

if not exist "%PS1%" (
    echo No se encuentra YtDOWNLOADER.ps1 junto a este archivo .bat
    echo Copia YtDOWNLOADER.bat y YtDOWNLOADER.ps1 en la misma carpeta.
    pause
    exit /b 1
)

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo.
    echo AVISO: No estas ejecutando YtDOWNLOADER como administrador.
    echo Normalmente NO es obligatorio. Es mejor usarlo sin administrador.
    echo Si Windows bloquea descargas, permisos, SmartScreen o antivirus,
    echo cierra esta ventana y usa: clic derecho sobre YtDOWNLOADER.bat ^> Ejecutar como administrador.
    echo.
)

powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%PS1%"
if errorlevel 1 (
    echo.
    echo La aplicacion se cerro con error.
    echo Revisa este archivo:
    echo "%ERRLOG%"
    echo.
    pause
    exit /b 1
)

exit /b 0
