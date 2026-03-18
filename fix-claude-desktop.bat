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
set INSTALL_TYPE=unknown
set CLAUDE_EXE=

REM ============================================================
REM Step 1: Claude関連プロセスの完全終了
REM ============================================================
echo [Step 1/9] Claude関連プロセスを完全終了...
taskkill /f /im "Claude.exe" >nul 2>&1
taskkill /f /im "claude.exe" >nul 2>&1
timeout /t 3 /nobreak >nul
echo   完了
echo.

REM ============================================================
REM Step 2: インストール形式の検出 (MSIX / Squirrel)
REM ============================================================
echo [Step 2/9] インストール形式を検出...

REM MSIX版の検出
powershell -NoProfile -Command "Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty PackageFullName" 2>nul | findstr /r "Claude" >nul 2>&1
if not errorlevel 1 (
    set INSTALL_TYPE=msix
    echo   インストール形式: MSIX (Windows App)
    for /f "tokens=*" %%a in ('powershell -NoProfile -Command "(Get-AppxPackage -Name 'Claude' | Sort-Object Version -Descending | Select-Object -First 1).PackageFamilyName" 2^>nul') do set MSIX_FAMILY=%%a
    for /f "tokens=*" %%a in ('powershell -NoProfile -Command "(Get-AppxPackage -Name 'Claude' | Sort-Object Version -Descending | Select-Object -First 1).Version" 2^>nul') do echo   バージョン: %%a
)

REM Squirrel版の検出
if exist "%LOCAL_APP%\AnthropicClaude\claude.exe" (
    if "%INSTALL_TYPE%"=="msix" (
        echo   [警告] 旧Squirrelインストールも残存: %LOCAL_APP%\AnthropicClaude
    ) else (
        set INSTALL_TYPE=squirrel
        set "CLAUDE_EXE=%LOCAL_APP%\AnthropicClaude\claude.exe"
        echo   インストール形式: Squirrel (旧形式)
        echo   実行ファイル: %CLAUDE_EXE%
    )
)

REM 従来パスの検索
if "%INSTALL_TYPE%"=="unknown" (
    if exist "%LOCAL_APP%\Programs\claude\Claude.exe" (
        set "CLAUDE_EXE=%LOCAL_APP%\Programs\claude\Claude.exe"
        set INSTALL_TYPE=standalone
    )
    if exist "%LOCAL_APP%\Programs\Claude\Claude.exe" (
        set "CLAUDE_EXE=%LOCAL_APP%\Programs\Claude\Claude.exe"
        set INSTALL_TYPE=standalone
    )
)

if "%INSTALL_TYPE%"=="unknown" (
    echo   [問題] Claude Desktopのインストールが見つかりません
    echo   再インストールが必要です: https://claude.ai/download
) else if "%INSTALL_TYPE%"=="standalone" (
    echo   インストール形式: スタンドアロン
    echo   実行ファイル: %CLAUDE_EXE%
)
echo.

REM ============================================================
REM Step 3: CoworkVMService 競合の確認
REM ============================================================
echo [Step 3/9] CoworkVMService 競合を確認...
REM CoworkVMService はClaude MSIX内の cowork-svc.exe の残留サービス。
REM MSIXパッケージ型サービスのため sc.exe delete では削除不可。レジストリ削除が必要。
sc query CoworkVMService >nul 2>&1
if not errorlevel 1 (
    echo   [問題] CoworkVMService が検出されました
    echo   Claude (cowork-svc.exe) の残留サービスです。起動失敗の原因になります。
    echo.
    net session >nul 2>&1
    if not errorlevel 1 (
        echo   管理者権限を検出。自動対処します...
        sc.exe stop CoworkVMService >nul 2>&1
        REM レジストリから直接削除 (sc.exe deleteはMSIXパッケージ型サービスに使用不可)
        reg delete "HKLM\SYSTEM\CurrentControlSet\Services\CoworkVMService" /f >nul 2>&1
        if not errorlevel 1 (
            echo   レジストリからサービスを削除しました
        ) else (
            echo   削除に失敗。PowerShell版スクリプトの使用を推奨します
        )
    ) else (
        echo   [要管理者権限] 管理者権限でPowerShellを起動し以下を実行:
        echo     Remove-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CoworkVMService' -Recurse -Force
    )
) else (
    echo   CoworkVMService なし - OK
)
echo.

REM ============================================================
REM Step 4: 旧Squirrelインストールのクリーンアップ
REM ============================================================
echo [Step 4/9] 旧Squirrelインストールのクリーンアップ...
if "%INSTALL_TYPE%"=="msix" (
    if exist "%LOCAL_APP%\AnthropicClaude" (
        echo   MSIX版がインストール済みのため、旧Squirrelインストールを削除します。
        if exist "%LOCAL_APP%\AnthropicClaude\Update.exe" (
            echo   Squirrelアンインストーラーを実行中...
            "%LOCAL_APP%\AnthropicClaude\Update.exe" --uninstall >nul 2>&1
        )
        rmdir /s /q "%LOCAL_APP%\AnthropicClaude" >nul 2>&1
        if not exist "%LOCAL_APP%\AnthropicClaude" (
            echo   削除完了
        ) else (
            echo   一部のファイルが削除できませんでした。手動で削除してください:
            echo   rmdir /s /q "%LOCAL_APP%\AnthropicClaude"
        )
    ) else (
        echo   旧Squirrelインストールなし - OK
    )
) else (
    echo   スキップ (MSIX版ではないため)
)
echo.

REM ============================================================
REM Step 5: Visual C++ ランタイムの確認
REM ============================================================
echo [Step 5/9] Visual C++ ランタイムを確認...
if exist "%SystemRoot%\System32\vcruntime140.dll" (
    echo   vcruntime140.dll: OK
) else (
    echo   [問題] Visual C++ Redistributable が見つかりません
    echo   ダウンロード: https://aka.ms/vs/17/release/vc_redist.x64.exe
)
echo.

REM ============================================================
REM Step 6: 設定ファイルのバックアップ
REM ============================================================
echo [Step 6/9] 設定ファイルをバックアップ...
if exist "%CONFIG_FILE%" (
    copy "%CONFIG_FILE%" "%CONFIG_FILE%.backup.%date:~0,4%%date:~5,2%%date:~8,2%" >nul 2>&1
    echo   バックアップ完了
) else (
    echo   設定ファイルなし。スキップ。
)
echo.

REM ============================================================
REM Step 7: ユーザーデータの完全リセット
REM ============================================================
echo [Step 7/9] ユーザーデータをリセット (設定ファイルは保持)...

for %%d in (Cache "Code Cache" GPUCache DawnCache DawnWebGPUCache blob_storage "Session Storage" "Local Storage" IndexedDB "Service Worker" "Shared Dictionary" WebStorage Network databases CachedData Crashpad logs tmp) do (
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
REM Step 8: 設定ファイルの検証・修復
REM ============================================================
echo [Step 8/9] 設定ファイルを検証...
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
REM Step 9: 修復後の起動テスト
REM ============================================================
echo [Step 9/9] 修復後の起動テスト...
if "%INSTALL_TYPE%"=="msix" (
    if defined MSIX_FAMILY (
        echo   MSIX版Claude Desktopを起動しています...
        start "" explorer.exe "shell:AppsFolder\%MSIX_FAMILY%!Claude"
        timeout /t 8 /nobreak >nul
        tasklist /fi "imagename eq Claude.exe" 2>nul | find "Claude.exe" >nul
        if not errorlevel 1 (
            echo   プロセスの起動を確認しました
        ) else (
            echo   プロセスが検出されません。起動に時間がかかっている可能性があります
            timeout /t 5 /nobreak >nul
            tasklist /fi "imagename eq Claude.exe" 2>nul | find "Claude.exe" >nul
            if not errorlevel 1 (
                echo   起動成功！(遅延起動)
            ) else (
                echo   起動に失敗しました
            )
        )
    ) else (
        echo   MSIXパッケージ情報が取得できないためスキップ
    )
) else if defined CLAUDE_EXE (
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
echo インストール形式: %INSTALL_TYPE%
echo.
echo 実行された修復:
echo   - Claude関連プロセスの完全終了
echo   - インストール形式の検出と整合性チェック
echo   - CoworkVMService競合の確認
echo   - 旧Squirrelインストールのクリーンアップ
echo   - キャッシュ・一時ファイルの完全削除
echo   - ユーザーデータのリセット
echo   - 設定ファイルの検証
echo   - 起動テスト
echo.
echo まだ起動しない場合:
if "%INSTALL_TYPE%"=="msix" (
    echo   1. MSIXパッケージを強制再インストール:
    echo      PowerShellで: Get-AppxPackage 'Claude' ^| Remove-AppxPackage
    echo      その後、https://claude.ai/download から再インストール
    echo   2. CoworkVMServiceが存在する場合は管理者権限で削除:
    echo      sc.exe delete CoworkVMService
) else (
    echo   1. 再インストール: https://claude.ai/download
    echo   2. 完全リセット: "%CONFIG_DIR%" フォルダを削除後に再インストール
)
echo   3. Visual C++ Redistributable: https://aka.ms/vs/17/release/vc_redist.x64.exe
echo   4. Windows Updateで最新の状態にする
echo.
echo バックアップ: %CONFIG_FILE%.backup.*
echo.
pause
