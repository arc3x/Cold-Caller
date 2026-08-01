@echo off
rem ===========================================================
rem  Copies ColdCaller.lua from the repo root (one level up)
rem  into your WoW Classic Era AddOns folder.
rem  Put this .bat in the same folder as your other scripts
rem  (e.g. \utils), so that "..\" points at the addon files.
rem  * THIS ASSUME YOU HAVE THE DEFAULT WoW INSTALL PATH AND ARE USING WINDOWS *
rem ===========================================================
setlocal

set "SRC=%~dp0..\ColdCaller.lua"
set "DESTDIR=C:\Program Files (x86)\World of Warcraft\_classic_era_\Interface\AddOns\ColdCaller"

if not exist "%SRC%" (
    echo ERROR: source not found: "%SRC%"
    goto :end
)

if not exist "%DESTDIR%" mkdir "%DESTDIR%"

copy /Y "%SRC%" "%DESTDIR%\ColdCaller.lua"

if errorlevel 1 (
    echo.
    echo Copy FAILED. If it says "Access denied", right-click this file
    echo and choose "Run as administrator" - Program Files is protected.
) else (
    echo.
    echo Done: ColdCaller.lua copied to the AddOns folder.
)

:end