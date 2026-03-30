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
echo [Step 1/12] Claude関連プロセスを完全終了...
taskkill /f /im "Claude.exe" >nul 2>&1
taskkill /f /im "claude.exe" >nul 2>&1
timeout /t 3 /nobreak >nul
echo   完了
echo.

REM ============================================================
REM Step 2: インストール形式の検出 (MSIX / Squirrel)
REM ============================================================
echo [Step 2/12] インストール形式を検出...

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
REM Step 3: インストールログの分析と原因特定
REM ============================================================
echo [Step 3/12] インストールログを分析...

REM 3a: Squirrel インストールログの確認
if exist "%LOCAL_APP%\SquirrelTemp\Squirrel-Install.log" (
    echo   Squirrelインストールログ: %LOCAL_APP%\SquirrelTemp\Squirrel-Install.log
    findstr /i "error fail exception fatal" "%LOCAL_APP%\SquirrelTemp\Squirrel-Install.log" >nul 2>&1
    if not errorlevel 1 (
        echo   [問題] Squirrelログにエラーを検出:
        for /f "tokens=*" %%a in ('findstr /i "error fail exception fatal" "%LOCAL_APP%\SquirrelTemp\Squirrel-Install.log" 2^>nul') do echo     %%a
    ) else (
        echo   Squirrelログ: エラーなし
    )
) else (
    echo   Squirrelインストールログなし
)

REM 3b: MSIX デプロイメントログの確認
echo.
echo   MSIXデプロイメントログを確認...
powershell -NoProfile -Command "try { $events = Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' -MaxEvents 200 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'Claude' -and $_.TimeCreated -gt (Get-Date).AddDays(-7) -and $_.Level -le 2 } | Select-Object -First 5; if ($events) { Write-Host '  [問題] MSIXデプロイメントエラーを検出:' -ForegroundColor Red; foreach ($e in $events) { $m = $e.Message; if ($m.Length -gt 200) { $m = $m.Substring(0,200) + '...' }; Write-Host ('    [' + $e.TimeCreated.ToString('yyyy/MM/dd HH:mm:ss') + '] ' + $m) -ForegroundColor DarkYellow; if ($e.Message -match '0x80073CF6') { Write-Host '    -> パッケージ競合 (CoworkVMService関連の可能性)' -ForegroundColor Yellow }; if ($e.Message -match '0x80073CFA') { Write-Host '    -> 旧パッケージ削除失敗' -ForegroundColor Yellow }; if ($e.Message -match '0x80073CFB') { Write-Host '    -> 依存パッケージ不足' -ForegroundColor Yellow } } } else { Write-Host '  直近7日間のClaude関連デプロイメントエラーなし' -ForegroundColor Green } } catch { Write-Host '  MSIXデプロイメントログの読み取りに失敗' -ForegroundColor Gray }" 2>nul

REM 3c: Windows Applicationイベントログの確認
echo.
echo   Windowsアプリケーションログを確認...
powershell -NoProfile -Command "try { $events = Get-WinEvent -LogName Application -MaxEvents 500 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'Claude' -and $_.Level -le 2 -and $_.TimeCreated -gt (Get-Date).AddDays(-7) } | Select-Object -First 5; if ($events) { Write-Host '  [問題] Claude関連のアプリケーションエラー:' -ForegroundColor Red; foreach ($e in $events) { $m = $e.Message; if ($m.Length -gt 200) { $m = $m.Substring(0,200) + '...' }; Write-Host ('    [' + $e.TimeCreated.ToString('yyyy/MM/dd HH:mm:ss') + '] (ID:' + $e.Id + ') ' + $m) -ForegroundColor DarkYellow; if ($e.Message -match 'CoreMessaging\.dll') { Write-Host '    -> CoreMessaging.dll 互換性問題 (Faulting module)' -ForegroundColor Yellow }; if ($e.Message -match 'VCRUNTIME140|vcruntime140|MSVCP140') { Write-Host '    -> Visual C++ ランタイム不足/破損' -ForegroundColor Yellow } } } else { Write-Host '  直近7日間のClaude関連エラーなし' -ForegroundColor Green } } catch { Write-Host '  アプリケーションログの読み取りに失敗' -ForegroundColor Gray }" 2>nul

REM 3d: Claude Desktopアプリログの確認
echo.
echo   Claude Desktopアプリログを確認...
if exist "%CONFIG_DIR%\logs" (
    echo   ログディレクトリ: %CONFIG_DIR%\logs
    for %%f in ("%CONFIG_DIR%\logs\*.log") do (
        echo   ログファイル: %%f
        findstr /i "error fatal crash fail uncaughtException" "%%f" >nul 2>&1
        if not errorlevel 1 (
            echo   [問題] ログにエラーを検出:
            for /f "tokens=*" %%a in ('findstr /i "error fatal crash fail" "%%f" 2^>nul') do echo     %%a
        )
    )
) else (
    echo   Claude Desktopログなし (初回起動に失敗している可能性)
)

REM 3e: クラッシュダンプの確認
if exist "%CONFIG_DIR%\Crashpad" (
    dir /b "%CONFIG_DIR%\Crashpad\*.dmp" >nul 2>&1
    if not errorlevel 1 (
        echo   [問題] クラッシュダンプファイルが存在します
        for %%f in ("%CONFIG_DIR%\Crashpad\*.dmp") do echo     %%~nxf (%%~tf)
    )
)
echo.

REM ============================================================
REM Step 4: CoworkVMService 競合の確認と除去
REM ============================================================
echo [Step 4/12] CoworkVMService 競合を確認...
REM CoworkVMService はClaude MSIXパッケージが所有するサービス。
REM 更新インストール時に競合し HRESULT 0x80073CF6 エラーの原因になる。
REM 解決策: MSIXパッケージを先に削除してからレジストリ残留を除去する。
sc query CoworkVMService >nul 2>&1
if not errorlevel 1 (
    echo   [問題] CoworkVMService が検出されました
    echo   Claude MSIXパッケージが所有するサービスです。
    echo   更新インストール時に HRESULT 0x80073CF6 エラーの原因になります。
    echo.
    net session >nul 2>&1
    if not errorlevel 1 (
        echo   管理者権限を検出。自動対処します...
        echo.
        REM Step 3a: サービスの停止
        sc.exe stop CoworkVMService >nul 2>&1
        REM Step 3b: CoworkVMService を所有するMSIXパッケージを先に削除
        echo   CoworkVMService を所有するMSIXパッケージを削除します...
        powershell -NoProfile -Command "Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ('  削除中: ' + $_.PackageFullName); try { Remove-AppxPackage -Package $_.PackageFullName -ErrorAction Stop; Write-Host '  削除成功' } catch { try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop; Write-Host '  AllUsersで削除成功' } catch { Write-Host ('  削除失敗: ' + $_.Exception.Message) } } }" 2>nul
        timeout /t 2 /nobreak >nul
        REM Step 3c: パッケージ削除後にサービスのレジストリ残留を削除
        sc query CoworkVMService >nul 2>&1
        if not errorlevel 1 (
            echo   パッケージ削除後もサービスが残留。レジストリから削除します...
            sc.exe delete CoworkVMService >nul 2>&1
            if not errorlevel 1 (
                echo   sc.exe delete で削除成功
            ) else (
                reg delete "HKLM\SYSTEM\CurrentControlSet\Services\CoworkVMService" /f >nul 2>&1
                if not errorlevel 1 (
                    echo   レジストリからサービスを削除しました
                ) else (
                    echo   [重要] 削除に失敗しました
                    echo   PCを再起動してから、このスクリプトを再実行してください
                )
            )
        ) else (
            echo   CoworkVMService が正常に削除されました
        )
        echo.
        echo   [注意] Claude MSIXパッケージも削除されました。
        echo   このスクリプト完了後、Claude Setup を実行して再インストールしてください。
    ) else (
        echo   [要管理者権限] サービスの除去には管理者権限が必要です。
        echo   管理者権限でこのスクリプトを再実行してください。
        echo.
        echo   手動対処手順:
        echo     1. 管理者権限でPowerShellを起動
        echo     2. Get-AppxPackage 'Claude' ^| Remove-AppxPackage
        echo     3. Remove-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CoworkVMService' -Recurse -Force
        echo     4. PCを再起動
        echo     5. Claude Setup を実行して再インストール
    )
) else (
    echo   CoworkVMService なし - OK
)
echo.

REM ============================================================
REM Step 5: 旧Squirrelインストールのクリーンアップ
REM ============================================================
echo [Step 5/12] 旧Squirrelインストールのクリーンアップ...
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
REM Step 6: Visual C++ ランタイムの確認
REM ============================================================
echo [Step 6/12] Visual C++ ランタイムを確認...
if exist "%SystemRoot%\System32\vcruntime140.dll" (
    echo   vcruntime140.dll: OK
) else (
    echo   [問題] Visual C++ Redistributable が見つかりません
    echo   ダウンロード: https://aka.ms/vs/17/release/vc_redist.x64.exe
)
echo.

REM ============================================================
REM Step 7: CoreMessaging.dll の確認
REM ============================================================
echo [Step 7/12] CoreMessaging.dll を確認...
if exist "%SystemRoot%\System32\CoreMessaging.dll" (
    echo   CoreMessaging.dll: 存在確認OK
) else (
    echo   [問題] CoreMessaging.dll が見つかりません
    echo   DISM /Online /Cleanup-Image /RestoreHealth で修復してください
)
echo.

REM ============================================================
REM Step 8: Windows バージョン互換性チェック + CoreMessaging.dll自動修復
REM ============================================================
echo [Step 8/12] Windows バージョン互換性を確認...
for /f "tokens=2 delims==" %%a in ('wmic os get BuildNumber /value 2^>nul ^| findstr BuildNumber') do set OS_BUILD=%%a
if defined OS_BUILD (
    echo   Windows ビルド: %OS_BUILD%
    if %OS_BUILD% LSS 17763 (
        echo   [問題] Windows 10 バージョン 1809 (ビルド 17763) 以降が必要です
        echo   Windows Updateで最新バージョンに更新してください
    ) else if %OS_BUILD% LEQ 19044 (
        echo.
        echo   ============================================================
        echo   [重大] このWindows 10はサービス終了(サポート切れ)です！
        echo   ============================================================
        echo.
        echo   これがClaude Desktop起動失敗の主要原因です。
        echo   古いCoreMessaging.dllがClaude MSIX版と互換性がありません。
        echo.
        echo   === 対処法 ===
        echo   [推奨] Windows 10 を最新バージョン (22H2) に更新:
        echo     1. 設定 → 更新とセキュリティ → Windows Update → 更新プログラムのチェック
        echo     2. または以下からWindows 10 更新アシスタントをダウンロード:
        echo        https://www.microsoft.com/ja-jp/software-download/windows10
        echo   [代替] Windows 11 にアップグレード:
        echo        https://www.microsoft.com/ja-jp/software-download/windows11
        echo.
    ) else (
        echo   Windows バージョン: 互換性OK
    )
) else (
    echo   ビルド番号の取得に失敗しました
)

REM CoreMessaging.dll クラッシュの自動検出
echo   CoreMessaging.dll クラッシュ履歴を確認...
powershell -NoProfile -Command "try { $crash = Get-WinEvent -LogName Application -MaxEvents 200 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'Claude' -and $_.Message -match 'CoreMessaging\.dll' } | Select-Object -First 1; if ($crash) { Write-Host '  [問題] CoreMessaging.dll クラッシュを検出' -ForegroundColor Red; exit 1 } else { Write-Host '  CoreMessaging.dll クラッシュ履歴なし' -ForegroundColor Green; exit 0 } } catch { exit 0 }" 2>nul
if %errorlevel% equ 1 set COREMSG_CRASH=1

REM CoreMessaging.dll クラッシュが検出された場合、Windows 8互換モードを自動設定
if defined COREMSG_CRASH (
    echo   Windows 8 互換モードを自動設定しています...
    if "%INSTALL_TYPE%"=="msix" (
        for /f "tokens=*" %%a in ('powershell -NoProfile -Command "(Get-AppxPackage -Name 'Claude' | Sort-Object Version -Descending | Select-Object -First 1).InstallLocation" 2^>nul') do (
            if exist "%%a\Claude.exe" (
                reg add "HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers" /v "%%a\Claude.exe" /d "~ WIN8RTM" /f >nul 2>&1
                echo   互換モード設定完了: %%a\Claude.exe
            )
        )
    ) else if defined CLAUDE_EXE (
        reg add "HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers" /v "%CLAUDE_EXE%" /d "~ WIN8RTM" /f >nul 2>&1
        echo   互換モード設定完了: %CLAUDE_EXE%
    )

    REM 管理者権限があればsfc/DISMも実行
    net session >nul 2>&1
    if not errorlevel 1 (
        echo.
        echo   管理者権限を検出。システムファイル修復を実行します...
        echo   sfc /scannow を実行中 (数分かかります)...
        sfc /scannow >nul 2>&1
        echo   sfc 完了
        echo   DISM /RestoreHealth を実行中 (数分かかります)...
        DISM /Online /Cleanup-Image /RestoreHealth >nul 2>&1
        echo   DISM 完了
    ) else (
        echo   [情報] sfc/DISM は管理者権限が必要です。管理者として再実行してください。
    )
)
echo.

REM ============================================================
REM Step 8: 設定ファイルのバックアップ
REM ============================================================
echo [Step 9/12] 設定ファイルをバックアップ...
if exist "%CONFIG_FILE%" (
    copy "%CONFIG_FILE%" "%CONFIG_FILE%.backup.%date:~0,4%%date:~5,2%%date:~8,2%" >nul 2>&1
    echo   バックアップ完了
) else (
    echo   設定ファイルなし。スキップ。
)
echo.

REM ============================================================
REM Step 10: ユーザーデータの完全リセット
REM ============================================================
echo [Step 10/12] ユーザーデータをリセット (設定ファイルは保持)...

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
REM Step 11: 設定ファイルの検証・修復
REM ============================================================
echo [Step 11/12] 設定ファイルを検証...
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
REM Step 12: 修復後の起動テスト
REM ============================================================
echo [Step 12/12] 修復後の起動テスト...
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

REM 起動失敗時の追加リカバリ
tasklist /fi "imagename eq Claude.exe" 2>nul | find "Claude.exe" >nul
if errorlevel 1 (
    echo.
    echo ============================================
    echo  起動に失敗しました。追加修復を試みます...
    echo ============================================
    echo.

    REM Phase 1: 互換モード + --disable-gpu --no-sandbox で再試行 (非MSIX)
    if not "%INSTALL_TYPE%"=="msix" if defined CLAUDE_EXE (
        echo [追加修復] --disable-gpu --no-sandbox で再試行...
        start "" "%CLAUDE_EXE%" --disable-gpu --no-sandbox
        timeout /t 10 /nobreak >nul
        tasklist /fi "imagename eq Claude.exe" 2>nul | find "Claude.exe" >nul
        if not errorlevel 1 (
            echo   起動成功！(GPU/サンドボックス無効モード)
            goto :summary
        )
    )

    echo.
    echo   全ての自動修復が失敗しました。
    echo   再インストールを推奨します。
    echo.
    if "%INSTALL_TYPE%"=="msix" (
        echo   再インストール手順:
        echo     1. 管理者PowerShellで: Get-AppxPackage 'Claude' ^| Remove-AppxPackage
        echo     2. PCを再起動
        echo     3. https://claude.ai/download から再インストール
        echo.
        set /p "DOREINSTALL=MSIXパッケージを削除して再インストール準備をしますか？ (y/N): "
        if /i "%DOREINSTALL%"=="y" (
            echo   MSIXパッケージを削除しています...
            powershell -NoProfile -Command "Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue" 2>nul
            echo   削除完了。
            echo.
            echo   次のステップ:
            echo     1. PCを再起動してください
            echo     2. ブラウザで https://claude.ai/download を開いてください
            echo     3. ダウンロードしたインストーラーを実行してください
            echo.
            set /p "OPENURL=ダウンロードページをブラウザで開きますか？ (y/N): "
            if /i "%OPENURL%"=="y" start "" "https://claude.ai/download"
        )
    ) else (
        echo   再インストール手順:
        echo     1. コントロールパネルからClaude Desktopをアンインストール
        echo     2. %CONFIG_DIR% フォルダを削除
        echo     3. PCを再起動
        echo     4. https://claude.ai/download から再インストール
        echo.
        set /p "OPENURL=ダウンロードページをブラウザで開きますか？ (y/N): "
        if /i "%OPENURL%"=="y" start "" "https://claude.ai/download"
    )
)

:summary
REM ============================================================
REM 結果サマリー
REM ============================================================
echo.
echo ============================================
echo  修復完了！
echo ============================================
echo.
echo インストール形式: %INSTALL_TYPE%
echo.
echo 実行された修復:
echo   - Claude関連プロセスの完全終了
echo   - インストール形式の検出と整合性チェック
echo   - インストールログの分析と原因特定
echo   - CoworkVMService競合の確認
echo   - 旧Squirrelインストールのクリーンアップ
echo   - キャッシュ・一時ファイルの完全削除
echo   - ユーザーデータのリセット
echo   - 設定ファイルの検証
if defined COREMSG_CRASH (
    echo   - CoreMessaging.dll 互換モード設定
    echo   - sfc/DISM システムファイル修復
)
echo   - 起動テスト
echo.
echo まだ起動しない場合:
if "%INSTALL_TYPE%"=="msix" (
    echo   1. MSIXパッケージを強制再インストール:
    echo      PowerShellで: Get-AppxPackage 'Claude' ^| Remove-AppxPackage
    echo      その後、https://claude.ai/download から再インストール
    echo   2. CoworkVMService が原因の場合 (HRESULT 0x80073CF6):
    echo      管理者PowerShellで以下を順に実行:
    echo        Get-AppxPackage 'Claude' ^| Remove-AppxPackage
    echo        Remove-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CoworkVMService' -Recurse -Force
    echo      その後PCを再起動し、Claude Setup を実行
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
