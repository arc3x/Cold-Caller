@echo off
rem ============================================================
rem  Double-click me to package the addon in THIS folder.
rem  Produces  build\<AddonName>.zip  with no .git clutter.
rem ============================================================
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Addon.ps1" %*
