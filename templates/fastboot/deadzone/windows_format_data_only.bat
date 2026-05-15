@echo off
cd %~dp0
set fastboot=bin\windows\fastboot.exe
if not exist %fastboot% echo %fastboot% not found. & pause & exit /B 1
echo Waiting for device...
set device=unknown
for /f "tokens=2" %%D in ('%fastboot% getvar product 2^>^&1 ^| findstr /l /b /c:"product:"') do set device=%%D

echo Detected device: %device%

echo WARNING: This will erase metadata and userdata.
choice /C YN /M "Continue with format data?"
if errorlevel 2 exit /B 1
%fastboot% set_active a
%fastboot% erase metadata
%fastboot% erase userdata
%fastboot% reboot
