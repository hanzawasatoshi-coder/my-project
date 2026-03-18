@echo off
chcp 65001 >nul 2>&1
echo ============================================
echo  Claude Desktop 起動エラー修正ツール
echo  対象: "Claude Desktop failed to Launch"
echo ============================================
echo.

set CONFIG_DIR=%APPDATA%\Claude
set CONFIG_FILE=%CONFIG_DIR%\claude_desktop_config.json
set LOCAL_APP=%LOCALAPPDATA%

REM ============================================================
REM Step 1: Claude関連プロセスの完全終了
REM ============================================================
echo [Step 1/7] Claude関連プロセスを完全終了...
taskkill /f /im "Claude.exe" >nul 2>&1
taskkill /f /im "claude.exe" >nul 2>&1
timeout /t 3 /nobreak >nul
echo   完了
echo.

REM ============================================================
REM Step 2: インストール状態の確認
REM ============================================================
echo [Step 2/7] インストール状態を確認...
set CLAUDE_EXE=
if exist "%LOCAL_APP%\Programs\claude\Claude.exe" (
    set "CLAUDE_EXE=%LOCAL_APP%\Programs\claude\Claude.exe"
)
if exist "%LOCAL_APP%\Programs\Claude\Claude.exe" (
    set "CLAUDE_EXE=%LOCAL_APP%\Programs\Claude\Claude.exe"
)
if defined CLAUDE_EXE (
    echo   実行ファイル: %CLAUDE_EXE%
) else (
    echo   [警告] Claude Desktopの実行ファイルが見つかりません
    echo   再インストールが必要です: https://claude.ai/download
)
echo.

REM ============================================================
REM Step 3: Visual C++ ランタイムの確認
REM ============================================================
echo [Step 3/7] Visual C++ ランタイムを確認...
if exist "%SystemRoot%\System32\vcruntime140.dll" (
    echo   vcruntime140.dll: OK
) else (
    echo   [問題] Visual C++ Redistributable が見つかりません
    echo   ダウンロード: https://aka.ms/vs/17/release/vc_redist.x64.exe
)
echo.

REM ============================================================
REM Step 4: 設定ファイルのバックアップ
REM ============================================================
echo [Step 4/7] 設定ファイルをバックアップ...
if exist "%CONFIG_FILE%" (
    copy "%CONFIG_FILE%" "%CONFIG_FILE%.backup.%date:~0,4%%date:~5,2%%date:~8,2%" >nul 2>&1
    echo   バックアップ完了
) else (
    echo   設定ファイルなし。スキップ。
)
echo.

REM ============================================================
REM Step 5: ユーザーデータの完全リセット
REM ============================================================
echo [Step 5/7] ユーザーデータをリセット (設定ファイルは保持)...

for %%d in (Cache "Code Cache" GPUCache DawnCache DawnWebGPUCache blob_storage "Session Storage" "Local Storage" IndexedDB "Service Worker" Network databases CachedData Crashpad logs tmp) do (
    if exist "%CONFIG_DIR%\%%~d" (
        rmdir /s /q "%CONFIG_DIR%\%%~d" >nul 2>&1
        echo   削除: %%~d/
    )
)

for %%f in (Cookies Cookies-journal Preferences "Local State" "Network Persistent State" TransportSecurity "Visited Links" "Web Data" "Web Data-journal" window-state.json) do (
    if exist "%CONFIG_DIR%\%%~f" (
        del /f /q "%CONFIG_DIR%\%%~f" >nul 2>&1
        echo   削除: %%~f
    )
)

echo   リセット完了
echo.

REM ============================================================
REM Step 6: 設定ファイルの検証・修復
REM ============================================================
echo [Step 6/7] 設定ファイルを検証...
if not exist "%CONFIG_DIR%" mkdir "%CONFIG_DIR%"

if not exist "%CONFIG_FILE%" (
    echo {} > "%CONFIG_FILE%"
    echo   空の設定ファイルを作成
) else (
    findstr /c:"{" "%CONFIG_FILE%" >nul 2>&1
    if errorlevel 1 (
        echo   [問題] 設定ファイルが破損。リセットします...
        echo {} > "%CONFIG_FILE%"
        echo   リセット完了
    ) else (
        echo   設定ファイル: OK
    )
)
echo.

REM ============================================================
REM Step 7: 修復後の起動テスト
REM ============================================================
echo [Step 7/7] 修復後の起動テスト...
if defined CLAUDE_EXE (
    echo   --disable-gpu オプションで起動しています...
    start "" "%CLAUDE_EXE%" --disable-gpu
    timeout /t 8 /nobreak >nul
    tasklist /fi "imagename eq Claude.exe" 2>nul | find "Claude.exe" >nul
    if not errorlevel 1 (
        echo   プロセスの起動を確認しました
    ) else (
        echo   起動に失敗しました
    )
) else (
    echo   実行ファイルが見つからないためスキップ
)
echo.

REM ============================================================
REM 結果サマリー
REM ============================================================
echo ============================================
echo  修復完了！
echo ============================================
echo.
echo 実行された修復:
echo   - Claude関連プロセスの完全終了
echo   - キャッシュ・一時ファイルの完全削除
echo   - ユーザーデータのリセット
echo   - 設定ファイルの検証
echo   - --disable-gpu オプションで起動テスト
echo.
echo まだ起動しない場合:
echo   1. 再インストール: https://claude.ai/download
echo   2. 完全リセット: "%CONFIG_DIR%" フォルダを削除後に再インストール
echo   3. Visual C++ Redistributable: https://aka.ms/vs/17/release/vc_redist.x64.exe
echo   4. Windows Updateで最新の状態にする
echo.
echo バックアップ: %CONFIG_FILE%.backup.*
echo.
pause
