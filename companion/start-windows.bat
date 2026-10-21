@echo off
cd /d "%~dp0"
where node >nul 2>nul || (echo Node.js 20+ e obrigatorio. Instale em https://nodejs.org/ & pause & exit /b 1)
node --version
node server.mjs
pause
