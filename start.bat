@echo off
rem ============================================================
rem  Starts the site on http://localhost:8080/ and forwards
rem  bookings to Telegram.
rem
rem  Bot token and chat_id are read from secrets.bat, which is
rem  excluded from git (.gitignore). To set up:
rem    copy secrets.example.bat secrets.bat
rem  and fill in your values. Run once without TELEGRAM_CHAT_ID
rem  to have the script print your chat_id.
rem ============================================================
if not exist "%~dp0secrets.bat" (
  echo secrets.bat not found. Copy secrets.example.bat to secrets.bat and fill it in.
  pause
  exit /b 1
)
call "%~dp0secrets.bat"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
pause
