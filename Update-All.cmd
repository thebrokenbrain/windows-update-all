@echo off
rem Lanzador de Update-All: doble clic para ejecutar. Admite los mismos parametros (-Auto, -DryRun, -Settings).
setlocal
set "SCRIPT=%~dp0Update-All.ps1"
where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
)
exit /b %errorlevel%
