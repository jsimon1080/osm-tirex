@echo off
REM Stop the TilesServer service
sc stop "TilesServer"

REM Disable the TilesServer service
sc config "TilesServer" start= disabled

echo TilesServer service stopped and disabled.
pause
