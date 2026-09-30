@echo off
rem Quietpane - double-click to start. It opens with your own rights; Windows asks for
rem administrator rights only when a change you press needs them.
rem Developed by KomodoWorks.com - free, open source, collects nothing.
if not exist "%~dp0src\Quietpane.psm1" goto notextracted
rem Windows can restrict PowerShell to signed scripts only (Smart App Control, or a work policy).
rem Then Quietpane cannot work, so say so here instead of failing out of sight.
set "QPMODE="
for /f "usebackq delims=" %%m in (`powershell.exe -NoProfile -Command "$ExecutionContext.SessionState.LanguageMode"`) do set "QPMODE=%%m"
if /i not "%QPMODE%"=="FullLanguage" goto restricted
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Quietpane.ps1"
exit /b

:notextracted
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName PresentationFramework; [void][System.Windows.MessageBox]::Show('Quietpane needs to be unzipped before it can start.' + [char]10 + [char]10 + '1. Close this message.' + [char]10 + '2. Right-click Quietpane.zip and choose Extract All, then Extract.' + [char]10 + '3. In the new folder, double-click Start Quietpane.', 'Quietpane')"
exit /b

:restricted
echo.
echo   Quietpane can't start on this PC yet.
echo.
echo   Windows here only runs apps that carry a digital signature. That is usually
echo   Smart App Control in Windows 11, or the rules on a work or school PC.
echo   Quietpane isn't signed yet - its certificate is on the way.
echo.
echo   Please don't switch Smart App Control off to run it: on many PCs, once
echo   it is off, Windows can't switch it back on without a reset.
echo.
echo   A signed version will be at github.com/kgntmr/quietpane
echo.
pause
exit /b
