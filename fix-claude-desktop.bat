@echo off
chcp 65001 >nul 2>&1
echo ============================================
echo  Claude Desktop 起動エラー修正ツール
echo ============================================
echo.

REM Step 1: Claude Desktopプロセスを終了
echo [Step 1] Claude Desktopプロセスを終了しています...
taskkill /f /im "Claude.exe" >nul 2>&1
taskkill /f /im "claude.exe" >nul 2>&1
timeout /t 2 /nobreak >nul
echo   完了
echo.

REM Step 2: 設定ファイルの確認
set CONFIG_DIR=%APPDATA%\Claude
set CONFIG_FILE=%CONFIG_DIR%\claude_desktop_config.json

echo [Step 2] 設定ファイルを確認しています...
echo   設定ファイルのパス: %CONFIG_FILE%

if not exist "%CONFIG_FILE%" (
    echo   設定ファイルが見つかりません。新規作成します...
    if not exist "%CONFIG_DIR%" mkdir "%CONFIG_DIR%"
    echo {} > "%CONFIG_FILE%"
    echo   空の設定ファイルを作成しました。
    goto :step3
)

REM 設定ファイルのバックアップ
echo   設定ファイルをバックアップしています...
copy "%CONFIG_FILE%" "%CONFIG_FILE%.backup.%date:~0,4%%date:~5,2%%date:~8,2%" >nul 2>&1
echo   バックアップ完了: %CONFIG_FILE%.backup.%date:~0,4%%date:~5,2%%date:~8,2%

REM JSONの簡易検証
findstr /c:"{" "%CONFIG_FILE%" >nul 2>&1
if errorlevel 1 (
    echo   [問題検出] 設定ファイルが破損しています。リセットします...
    echo {} > "%CONFIG_FILE%"
    echo   設定ファイルをリセットしました。
)
echo.

:step3
REM Step 3: キャッシュとGPU関連の修正
echo [Step 3] キャッシュをクリアしています...

set CACHE_DIRS="%APPDATA%\Claude\Cache" "%APPDATA%\Claude\Code Cache" "%APPDATA%\Claude\GPUCache"

for %%d in (%CACHE_DIRS%) do (
    if exist %%d (
        rmdir /s /q %%d >nul 2>&1
        echo   削除: %%d
    )
)
echo   キャッシュクリア完了
echo.

REM Step 4: ログファイルの確認
echo [Step 4] ログファイルを確認しています...
set LOG_DIR=%APPDATA%\Claude\logs
if exist "%LOG_DIR%" (
    echo   ログディレクトリ: %LOG_DIR%
    dir /b /o-d "%LOG_DIR%\*.log" 2>nul | findstr /n "^" | findstr "^[1-3]:"
    echo.
    echo   最新のログファイルの末尾を表示:
    for /f "delims=" %%f in ('dir /b /o-d "%LOG_DIR%\*.log" 2^>nul') do (
        echo   --- %LOG_DIR%\%%f ---
        type "%LOG_DIR%\%%f" 2>nul | more +0
        goto :after_log
    )
) else (
    echo   ログディレクトリが見つかりません。
)
:after_log
echo.

REM Step 5: GPU無効化オプション
echo [Step 5] GPUアクセラレーションの問題を確認...
echo   GPU関連のエラーが原因の場合、以下のショートカットで起動してください:
echo   "Claude.exe" --disable-gpu
echo.

echo ============================================
echo  修正完了！
echo ============================================
echo.
echo 次のステップ:
echo   1. Claude Desktopを再起動してください
echo   2. まだエラーが出る場合は、以下を試してください:
echo      a. アプリを再インストール (設定は保持されます)
echo      b. --disable-gpu オプション付きで起動
echo      c. %CONFIG_FILE% を確認
echo.
echo バックアップファイルの場所:
echo   %CONFIG_FILE%.backup.*
echo.
pause
