@echo off
rem ===========================================================
rem  Copies the addon's runtime files from the repo root (one
rem  level up) into your WoW Classic Era AddOns folder.
rem  Put this .bat in the same folder as your other scripts
rem  (e.g. \utils), so that "..\" points at the addon files.
rem  * THIS ASSUME YOU HAVE THE DEFAULT WoW INSTALL PATH AND ARE USING WINDOWS *
rem ===========================================================
setlocal

set "SRCDIR=%~dp0.."
set "DESTDIR=C:\Program Files (x86)\World of Warcraft\_classic_era_\Interface\AddOns\ColdCaller"

if not exist "%SRCDIR%\ColdCaller.lua" (
    echo ERROR: source not found: "%SRCDIR%\ColdCaller.lua"
    goto :end
)

if not exist "%DESTDIR%" mkdir "%DESTDIR%"

copy /Y "%SRCDIR%\ColdCaller.lua" "%DESTDIR%\ColdCaller.lua"
copy /Y "%SRCDIR%\ColdCaller.toc" "%DESTDIR%\ColdCaller.toc"
copy /Y "%SRCDIR%\cold-caller-icon-sm.png" "%DESTDIR%\cold-caller-icon-sm.png"

if errorlevel 1 (
    echo.
    echo Copy FAILED. If it says "Access denied", right-click this file
    echo and choose "Run as administrator" - Program Files is protected.
) else (
    echo.
    echo Done: ColdCaller.lua, ColdCaller.toc, and the icon copied to the AddOns folder.
)

:end