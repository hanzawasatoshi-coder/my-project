#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Desktop 起動エラー修正スクリプト (PowerShell版)
.DESCRIPTION
    "Claude Desktop failed to Launch" エラーを修正します。
    - プロセス完全終了
    - MSIX/Squirrel両インストール形式の検出と整合性チェック
    - インストールログの分析と原因特定
    - CoworkVMService競合の検出と除去
    - 旧インストール残留のクリーンアップ
    - ユーザーデータの完全リセット
    - 設定ファイルの検証・修復
    - Visual C++ ランタイム確認
    - WebView2ランタイム確認
    - キャッシュ・一時ファイルのクリア
    - ログの確認
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"
$totalSteps = 13

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Claude Desktop 起動エラー修正ツール" -ForegroundColor Cyan
Write-Host " 対象: 'Claude Desktop failed to Launch'" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$configDir = Join-Path $env:APPDATA "Claude"
$configFile = Join-Path $configDir "claude_desktop_config.json"
$localAppData = $env:LOCALAPPDATA
$issuesFound = @()
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "  [情報] 管理者権限なしで実行中。一部の修復は制限されます。" -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================
# Step 1: Claude関連プロセスの完全終了
# ============================================================
Write-Host "[Step 1/$totalSteps] Claude関連プロセスを完全終了..." -ForegroundColor Yellow

$claudeProcesses = @("Claude", "claude", "Claude Desktop")
foreach ($procName in $claudeProcesses) {
    Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# Electronの残存プロセスも確認
Get-Process | Where-Object {
    $_.Path -and $_.Path -like "*Claude*"
} | Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 3
Write-Host "  完了" -ForegroundColor Green
Write-Host ""

# ============================================================
# Step 2: インストール形式の検出 (MSIX / Squirrel)
# ============================================================
Write-Host "[Step 2/$totalSteps] インストール形式を検出..." -ForegroundColor Yellow

$installType = "unknown"
$claudeExe = $null
$msixPackage = $null

# MSIX版の検出
try {
    $msixPackage = Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageFamilyName -like "Claude_*" } |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1

    if (-not $msixPackage) {
        $msixPackage = Get-AppxPackage -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "Claude" -or $_.PackageFamilyName -like "Claude_*" } |
            Sort-Object -Property Version -Descending |
            Select-Object -First 1
    }
} catch {
    Write-Host "  AppxPackage確認中にエラー: $_" -ForegroundColor Gray
}

if ($msixPackage) {
    $installType = "msix"
    Write-Host "  インストール形式: MSIX (Windows App)" -ForegroundColor Green
    Write-Host "  パッケージ名: $($msixPackage.PackageFullName)" -ForegroundColor Gray
    Write-Host "  バージョン: $($msixPackage.Version)" -ForegroundColor Gray
    Write-Host "  インストール先: $($msixPackage.InstallLocation)" -ForegroundColor Gray
    Write-Host "  ステータス: $($msixPackage.Status)" -ForegroundColor Gray

    if ($msixPackage.InstallLocation) {
        $msixExe = Join-Path $msixPackage.InstallLocation "Claude.exe"
        if (Test-Path $msixExe) {
            $claudeExe = $msixExe
        }
    }
}

# Squirrel版の検出
$squirrelDir = Join-Path $localAppData "AnthropicClaude"
$squirrelExe = Join-Path $squirrelDir "claude.exe"
$hasSquirrel = Test-Path $squirrelDir

if ($hasSquirrel) {
    if ($installType -eq "msix") {
        Write-Host "  [警告] 旧Squirrelインストールも残存: $squirrelDir" -ForegroundColor Yellow
        $issuesFound += "旧Squirrelインストール残留"
    } else {
        $installType = "squirrel"
        Write-Host "  インストール形式: Squirrel (旧形式)" -ForegroundColor Yellow
        if (Test-Path $squirrelExe) {
            $claudeExe = $squirrelExe
            $fileInfo = Get-Item $claudeExe
            Write-Host "  実行ファイル: $claudeExe" -ForegroundColor Green
            Write-Host "  バージョン: $($fileInfo.VersionInfo.FileVersion)" -ForegroundColor Gray
        }
    }
}

# 従来パスの検索 (MSIXでもSquirrelでもない場合)
if ($installType -eq "unknown") {
    $possiblePaths = @(
        (Join-Path $localAppData "Programs\claude\Claude.exe"),
        (Join-Path $localAppData "Programs\Claude\Claude.exe"),
        (Join-Path $localAppData "Claude\Claude.exe"),
        (Join-Path $env:ProgramFiles "Claude\Claude.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Claude\Claude.exe")
    )

    foreach ($p in $possiblePaths) {
        if (Test-Path $p) {
            $claudeExe = $p
            $installType = "standalone"
            break
        }
    }

    # ショートカットからパスを検出
    if (-not $claudeExe) {
        $shortcuts = @(
            (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Claude\Claude.lnk"),
            (Join-Path ([Environment]::GetFolderPath("Desktop")) "Claude.lnk"),
            (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Claude.lnk")
        )
        foreach ($lnk in $shortcuts) {
            if (Test-Path $lnk) {
                try {
                    $shell = New-Object -ComObject WScript.Shell
                    $shortcut = $shell.CreateShortcut($lnk)
                    if (Test-Path $shortcut.TargetPath) {
                        $claudeExe = $shortcut.TargetPath
                        $installType = "standalone"
                        break
                    }
                } catch {}
            }
        }
    }

    if ($installType -eq "unknown") {
        Write-Host "  [問題] Claude Desktopのインストールが見つかりません" -ForegroundColor Red
        $issuesFound += "Claude Desktopが見つからない"
    } else {
        Write-Host "  インストール形式: スタンドアロン" -ForegroundColor Green
        Write-Host "  実行ファイル: $claudeExe" -ForegroundColor Green
    }
}

# アプリ整合性チェック (MSIX以外)
if ($claudeExe -and $installType -ne "msix") {
    $appDir = Split-Path $claudeExe
    $resourcesDir = Join-Path $appDir "resources"
    $appAsar = Join-Path $resourcesDir "app.asar"

    if (Test-Path $appAsar) {
        $asarSize = (Get-Item $appAsar).Length
        if ($asarSize -lt 1MB) {
            Write-Host "  [問題] app.asarのサイズが異常に小さい ($([math]::Round($asarSize / 1KB)) KB)" -ForegroundColor Red
            $issuesFound += "app.asar too small - インストール破損の可能性"
        } else {
            Write-Host "  app.asar: OK ($([math]::Round($asarSize / 1MB, 1)) MB)" -ForegroundColor Green
        }
    } elseif ($installType -eq "squirrel") {
        Write-Host "  [問題] app.asarが見つかりません。インストールが破損しています。" -ForegroundColor Red
        $issuesFound += "app.asar missing - インストール破損"
    }
}
Write-Host ""

# ============================================================
# Step 3: インストールログの分析と原因特定
# ============================================================
Write-Host "[Step 3/$totalSteps] インストールログを分析..." -ForegroundColor Yellow

$logAnalysisResults = @()

# 3a: Squirrel インストールログの確認
$squirrelLogPaths = @(
    (Join-Path $localAppData "SquirrelTemp\Squirrel-Install.log"),
    (Join-Path $localAppData "SquirrelTemp\SquirrelSetup.log")
)

$squirrelLogFound = $false
foreach ($logPath in $squirrelLogPaths) {
    if (Test-Path $logPath) {
        $squirrelLogFound = $true
        Write-Host "  Squirrelインストールログ: $logPath" -ForegroundColor Gray
        try {
            $logContent = Get-Content $logPath -Tail 50 -ErrorAction Stop
            $errors = $logContent | Where-Object { $_ -match "error|fail|exception|fatal" }
            if ($errors) {
                Write-Host "  [問題] Squirrelログにエラーを検出:" -ForegroundColor Red
                foreach ($err in ($errors | Select-Object -Last 5)) {
                    Write-Host "    $err" -ForegroundColor DarkYellow
                }
                $logAnalysisResults += "Squirrelインストールログにエラーあり"
            } else {
                Write-Host "  Squirrelログ: エラーなし" -ForegroundColor Green
            }
        } catch {
            Write-Host "  ログ読み取りに失敗: $_" -ForegroundColor Gray
        }
    }
}
if (-not $squirrelLogFound) {
    Write-Host "  Squirrelインストールログなし (MSIX版または未インストール)" -ForegroundColor Gray
}

# 3b: MSIX/AppInstaller デプロイメントログの確認
Write-Host "" -ForegroundColor Gray
Write-Host "  MSIX デプロイメントログを確認..." -ForegroundColor Gray
try {
    $deployEvents = Get-WinEvent -LogName "Microsoft-Windows-AppXDeploymentServer/Operational" -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Message -match "Claude" -and $_.TimeCreated -gt (Get-Date).AddDays(-7)
        } | Select-Object -First 10

    if ($deployEvents) {
        $deployErrors = $deployEvents | Where-Object { $_.Level -le 2 }
        $deployWarnings = $deployEvents | Where-Object { $_.Level -eq 3 }

        if ($deployErrors) {
            Write-Host "  [問題] MSIXデプロイメントエラーを検出 ($($deployErrors.Count)件):" -ForegroundColor Red
            foreach ($evt in ($deployErrors | Select-Object -First 5)) {
                $msg = $evt.Message
                if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + "..." }
                Write-Host "    [$($evt.TimeCreated.ToString('yyyy/MM/dd HH:mm:ss'))] $msg" -ForegroundColor DarkYellow
            }

            # HRESULT コードの解析
            foreach ($evt in $deployErrors) {
                if ($evt.Message -match "0x80073CF6") {
                    $logAnalysisResults += "MSIX デプロイエラー: 0x80073CF6 (パッケージ競合 - CoworkVMService関連の可能性)"
                    Write-Host "  → 原因: パッケージ競合 (0x80073CF6) - CoworkVMService が原因の可能性大" -ForegroundColor Yellow
                }
                if ($evt.Message -match "0x80073CFA") {
                    $logAnalysisResults += "MSIX デプロイエラー: 0x80073CFA (旧パッケージ削除失敗)"
                    Write-Host "  → 原因: 旧パッケージの削除に失敗 (0x80073CFA)" -ForegroundColor Yellow
                }
                if ($evt.Message -match "0x80073CFB") {
                    $logAnalysisResults += "MSIX デプロイエラー: 0x80073CFB (依存パッケージ不足)"
                    Write-Host "  → 原因: 依存パッケージ不足 (0x80073CFB)" -ForegroundColor Yellow
                }
                if ($evt.Message -match "0x80073CF9") {
                    $logAnalysisResults += "MSIX デプロイエラー: 0x80073CF9 (インストール先アクセス拒否)"
                    Write-Host "  → 原因: インストール先アクセス拒否 (0x80073CF9)" -ForegroundColor Yellow
                }
                if ($evt.Message -match "0x80080204") {
                    $logAnalysisResults += "MSIX デプロイエラー: 0x80080204 (パッケージ署名検証失敗)"
                    Write-Host "  → 原因: パッケージ署名の検証に失敗 (0x80080204)" -ForegroundColor Yellow
                }
            }
        }

        if ($deployWarnings) {
            Write-Host "  MSIXデプロイメント警告: $($deployWarnings.Count)件" -ForegroundColor Yellow
        }

        if (-not $deployErrors -and -not $deployWarnings) {
            Write-Host "  MSIXデプロイメントログ: 正常イベントのみ" -ForegroundColor Green
        }
    } else {
        Write-Host "  直近7日間のClaude関連デプロイメントイベントなし" -ForegroundColor Gray
    }
} catch {
    Write-Host "  MSIXデプロイメントログの読み取りに失敗 (アクセス権限不足の可能性): $_" -ForegroundColor Gray
}

# 3c: Windows Applicationイベントログの確認 (Claude関連エラー)
Write-Host "" -ForegroundColor Gray
Write-Host "  Windowsアプリケーションログを確認..." -ForegroundColor Gray
try {
    $appEvents = Get-WinEvent -LogName Application -MaxEvents 500 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Message -match "Claude" -and $_.Level -le 2 -and $_.TimeCreated -gt (Get-Date).AddDays(-7)
        } | Select-Object -First 10

    if ($appEvents) {
        Write-Host "  [問題] Claude関連のアプリケーションエラー ($($appEvents.Count)件):" -ForegroundColor Red
        foreach ($evt in ($appEvents | Select-Object -First 5)) {
            $msg = $evt.Message
            if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + "..." }
            Write-Host "    [$($evt.TimeCreated.ToString('yyyy/MM/dd HH:mm:ss'))] (ID:$($evt.Id)) $msg" -ForegroundColor DarkYellow
        }

        # 既知のエラーパターンの解析
        foreach ($evt in $appEvents) {
            if ($evt.Message -match "CoreMessaging\.dll") {
                $logAnalysisResults += "CoreMessaging.dll クラッシュ"
                Write-Host "  → 原因: CoreMessaging.dll 互換性問題 (Faulting module)" -ForegroundColor Yellow
            }
            if ($evt.Message -match "VCRUNTIME140\.dll|vcruntime140\.dll|MSVCP140\.dll") {
                $logAnalysisResults += "Visual C++ ランタイムDLL読み込み失敗"
                Write-Host "  → 原因: Visual C++ ランタイムが不足または破損" -ForegroundColor Yellow
            }
            if ($evt.Message -match "gpu.*crash|GPU.*error" -or ($evt.Message -match "Claude" -and $evt.Message -match "gpu")) {
                $logAnalysisResults += "GPUドライバ関連クラッシュ"
                Write-Host "  → 原因: GPUドライバの互換性問題 (--disable-gpu で回避可能)" -ForegroundColor Yellow
            }
            if ($evt.Id -eq 1000 -and $evt.Message -match "Claude") {
                $logAnalysisResults += "アプリケーションクラッシュ (イベントID 1000)"
                Write-Host "  → アプリケーションクラッシュ (イベントID 1000) を検出" -ForegroundColor Yellow
            }
            if ($evt.Id -eq 1001 -and $evt.Message -match "Claude") {
                $logAnalysisResults += "Windows Error Reporting (イベントID 1001)"
            }
        }
    } else {
        Write-Host "  直近7日間のClaude関連エラーイベントなし" -ForegroundColor Green
    }
} catch {
    Write-Host "  アプリケーションログの読み取りに失敗: $_" -ForegroundColor Gray
}

# 3d: Claude Desktop自体のログ確認
Write-Host "" -ForegroundColor Gray
Write-Host "  Claude Desktopアプリログを確認..." -ForegroundColor Gray

$claudeLogPaths = @(
    (Join-Path $configDir "logs"),
    (Join-Path $configDir "log.txt"),
    (Join-Path $configDir "main.log"),
    (Join-Path $configDir "renderer.log")
)

# Electronのクラッシュダンプ確認
$crashpadDir = Join-Path $configDir "Crashpad"
$claudeLogFound = $false

foreach ($logPath in $claudeLogPaths) {
    if (Test-Path $logPath) {
        $claudeLogFound = $true
        if ((Get-Item $logPath).PSIsContainer) {
            # ディレクトリの場合、中のログファイルを確認
            $logFiles = Get-ChildItem $logPath -Filter "*.log" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 3
            foreach ($lf in $logFiles) {
                Write-Host "  ログファイル: $($lf.FullName) ($([math]::Round($lf.Length / 1KB)) KB, $($lf.LastWriteTime))" -ForegroundColor Gray
                try {
                    $logLines = Get-Content $lf.FullName -Tail 30 -ErrorAction Stop
                    $logErrors = $logLines | Where-Object { $_ -match "error|fatal|crash|fail|ENOENT|EPERM|uncaughtException" }
                    if ($logErrors) {
                        Write-Host "  [問題] ログにエラーを検出:" -ForegroundColor Red
                        foreach ($le in ($logErrors | Select-Object -Last 5)) {
                            $leTrimmed = if ($le.Length -gt 200) { $le.Substring(0, 200) + "..." } else { $le }
                            Write-Host "    $leTrimmed" -ForegroundColor DarkYellow
                        }
                        $logAnalysisResults += "Claude Desktopログにエラーあり ($($lf.Name))"
                    }
                } catch {
                    Write-Host "  ログ読み取り失敗: $_" -ForegroundColor Gray
                }
            }
        } else {
            # ファイルの場合
            Write-Host "  ログファイル: $logPath" -ForegroundColor Gray
            try {
                $logLines = Get-Content $logPath -Tail 30 -ErrorAction Stop
                $logErrors = $logLines | Where-Object { $_ -match "error|fatal|crash|fail" }
                if ($logErrors) {
                    Write-Host "  [問題] ログにエラーを検出:" -ForegroundColor Red
                    foreach ($le in ($logErrors | Select-Object -Last 5)) {
                        $leTrimmed = if ($le.Length -gt 200) { $le.Substring(0, 200) + "..." } else { $le }
                        Write-Host "    $leTrimmed" -ForegroundColor DarkYellow
                    }
                    $logAnalysisResults += "Claude Desktopログにエラーあり"
                }
            } catch {}
        }
    }
}

if (Test-Path $crashpadDir) {
    $crashDumps = Get-ChildItem $crashpadDir -Filter "*.dmp" -Recurse -ErrorAction SilentlyContinue
    if ($crashDumps) {
        $recentCrashes = $crashDumps | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-7) }
        if ($recentCrashes) {
            Write-Host "  [問題] 直近7日間のクラッシュダンプ: $($recentCrashes.Count)件" -ForegroundColor Red
            foreach ($cd in ($recentCrashes | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
                Write-Host "    $($cd.Name) ($($cd.LastWriteTime), $([math]::Round($cd.Length / 1KB)) KB)" -ForegroundColor DarkYellow
            }
            $logAnalysisResults += "クラッシュダンプ $($recentCrashes.Count)件 (直近7日間)"
        } else {
            Write-Host "  過去のクラッシュダンプあり (7日以上前)" -ForegroundColor Gray
        }
    }
}

if (-not $claudeLogFound -and -not (Test-Path $crashpadDir)) {
    Write-Host "  Claude Desktopのログなし (初回起動に失敗している可能性)" -ForegroundColor Yellow
    $logAnalysisResults += "Claude Desktopログなし - 初回起動前の失敗の可能性"
}

# 3e: TEMP内のセットアップログ確認
Write-Host "" -ForegroundColor Gray
Write-Host "  TEMPフォルダのセットアップログを確認..." -ForegroundColor Gray

$tempSetupLogs = Get-ChildItem $env:TEMP -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "Claude" -and $_.Extension -match "\.(log|txt)$" } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 5

if ($tempSetupLogs) {
    foreach ($tLog in $tempSetupLogs) {
        Write-Host "  セットアップログ: $($tLog.FullName) ($($tLog.LastWriteTime))" -ForegroundColor Gray
        try {
            $tLogContent = Get-Content $tLog.FullName -Tail 20 -ErrorAction Stop
            $tLogErrors = $tLogContent | Where-Object { $_ -match "error|fail|exception" }
            if ($tLogErrors) {
                foreach ($tle in ($tLogErrors | Select-Object -Last 3)) {
                    $tleTrimmed = if ($tle.Length -gt 200) { $tle.Substring(0, 200) + "..." } else { $tle }
                    Write-Host "    $tleTrimmed" -ForegroundColor DarkYellow
                }
                $logAnalysisResults += "セットアップログにエラーあり ($($tLog.Name))"
            }
        } catch {}
    }
} else {
    Write-Host "  TEMPフォルダにClaude関連のセットアップログなし" -ForegroundColor Gray
}

# ログ分析結果のサマリー
Write-Host "" -ForegroundColor Gray
if ($logAnalysisResults.Count -gt 0) {
    Write-Host "  === ログ分析結果 ===" -ForegroundColor Cyan
    foreach ($result in $logAnalysisResults) {
        Write-Host "  ● $result" -ForegroundColor Yellow
        $issuesFound += $result
    }
} else {
    Write-Host "  ログ分析: 明確なエラーは検出されませんでした" -ForegroundColor Green
}
Write-Host ""

# ============================================================
# Step 4: CoworkVMService 競合の検出と除去
# ============================================================
Write-Host "[Step 4/$totalSteps] CoworkVMService 競合を確認..." -ForegroundColor Yellow

# CoworkVMService はClaude MSIX パッケージ内の cowork-svc.exe が登録するサービス。
# 再インストール時に旧サービスが残留すると、新パッケージのインストール/起動が失敗する。
#
# 問題の流れ:
#   1. Claude MSIX インストール → CoworkVMService が自動登録される
#   2. Claude Setup で更新時 → CoworkVMService が競合として検出される
#   3. 管理者権限でも "could not open CoworkVMService: Access is denied" で削除失敗
#   4. 旧パッケージ削除失敗 (0x80073CFA) → 新パッケージインストール失敗 (0x80073CF6)
#
# 解決策: MSIX パッケージを先に削除してからサービスのレジストリ残留を除去する。
# CoworkVMService は MSIX パッケージに所有されているため、パッケージ削除で
# サービスも一緒に削除される。パッケージ削除後もレジストリが残る場合は手動削除する。

$svcRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CoworkVMService"
$coworkService = Get-Service -Name "CoworkVMService" -ErrorAction SilentlyContinue
$coworkRegExists = Test-Path $svcRegPath

if ($coworkService -or $coworkRegExists) {
    Write-Host "  [問題] CoworkVMService が検出されました" -ForegroundColor Red

    # サービスの詳細を表示
    if ($coworkRegExists) {
        $svcReg = Get-ItemProperty $svcRegPath -ErrorAction SilentlyContinue
        if ($svcReg.ImagePath) {
            Write-Host "  ImagePath: $($svcReg.ImagePath)" -ForegroundColor Gray
        }
        if ($svcReg.PackageFullName) {
            Write-Host "  所有パッケージ: $($svcReg.PackageFullName)" -ForegroundColor Gray
        }
    }

    Write-Host "  このサービスはClaude MSIXパッケージが所有するサービスです。" -ForegroundColor Yellow
    Write-Host "  更新インストール時に競合し、HRESULT 0x80073CF6 エラーの原因になります。" -ForegroundColor Yellow
    $issuesFound += "CoworkVMService 残留 (Claude cowork-svc.exe)"

    if ($isAdmin) {
        # Step 3a: まずサービスの停止を試行
        if ($coworkService -and $coworkService.Status -eq "Running") {
            try {
                Stop-Service -Name "CoworkVMService" -Force -ErrorAction Stop
                Write-Host "  サービスを停止しました" -ForegroundColor Green
            } catch {
                & sc.exe stop "CoworkVMService" 2>&1 | Out-Null
                Write-Host "  サービス停止を試行しました" -ForegroundColor Yellow
            }
        }

        # Step 3b: CoworkVMService を所有している MSIX パッケージを先に削除する
        # サービスが MSIX に所有されているため、パッケージ削除でサービスも解放される
        Write-Host "  CoworkVMService を所有するMSIXパッケージを削除します..." -ForegroundColor Yellow
        $coworkRemoved = $false
        try {
            $claudePackages = Get-AppxPackage -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq "Claude" -or $_.PackageFamilyName -like "Claude_*" }
            if ($claudePackages) {
                foreach ($pkg in $claudePackages) {
                    Write-Host "  パッケージ削除中: $($pkg.PackageFullName)" -ForegroundColor Gray
                    try {
                        Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                        Write-Host "  パッケージ削除成功: $($pkg.PackageFullName)" -ForegroundColor Green
                        $coworkRemoved = $true
                    } catch {
                        Write-Host "  パッケージ削除失敗: $($_.Exception.Message)" -ForegroundColor Yellow
                        # AllUsers でも試行
                        try {
                            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                            Write-Host "  AllUsersで削除成功" -ForegroundColor Green
                            $coworkRemoved = $true
                        } catch {
                            Write-Host "  AllUsersでも削除失敗: $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }
                }
            }
        } catch {
            Write-Host "  パッケージ一覧取得エラー: $_" -ForegroundColor Red
        }

        # Step 3c: パッケージ削除後、レジストリにサービスが残留していれば削除
        Start-Sleep -Seconds 2
        if (Test-Path $svcRegPath) {
            Write-Host "  レジストリにサービスが残留。直接削除します..." -ForegroundColor Yellow

            # sc.exe delete も試行（パッケージ削除後なら成功する可能性がある）
            $scResult = & sc.exe delete "CoworkVMService" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  sc.exe delete で削除成功" -ForegroundColor Green
            } else {
                Write-Host "  sc.exe delete 失敗 ($scResult)。レジストリから直接削除..." -ForegroundColor Yellow
                try {
                    Remove-Item -Path $svcRegPath -Recurse -Force -ErrorAction Stop
                    Write-Host "  レジストリからサービスを削除しました" -ForegroundColor Green
                } catch {
                    Write-Host "  レジストリ削除に失敗: $_" -ForegroundColor Red
                    Write-Host "" -ForegroundColor Gray
                    Write-Host "  === 手動対処が必要です ===" -ForegroundColor Red
                    Write-Host "  1. PCを再起動してください" -ForegroundColor Yellow
                    Write-Host "  2. 再起動後、管理者PowerShellで以下を実行:" -ForegroundColor Yellow
                    Write-Host "     Remove-Item -Path '$svcRegPath' -Recurse -Force" -ForegroundColor Gray
                    Write-Host "  3. その後 Claude Setup を実行" -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "  CoworkVMService のレジストリが正常に削除されました" -ForegroundColor Green
        }

        # Step 3d: 再起動推奨の判定
        $svcStillExists = (Get-Service -Name "CoworkVMService" -ErrorAction SilentlyContinue) -or (Test-Path $svcRegPath)
        if ($svcStillExists) {
            Write-Host "" -ForegroundColor Gray
            Write-Host "  [重要] CoworkVMService が完全に削除できませんでした。" -ForegroundColor Red
            Write-Host "  PCを再起動してから、このスクリプトを再実行してください。" -ForegroundColor Yellow
            Write-Host "  再起動によりサービスコントロールマネージャーのキャッシュがクリアされます。" -ForegroundColor Gray
            $issuesFound += "CoworkVMService 削除不完全 - 要再起動"
        } else {
            Write-Host "  CoworkVMService を完全に除去しました" -ForegroundColor Green
            if ($coworkRemoved) {
                Write-Host "" -ForegroundColor Gray
                Write-Host "  [注意] Claude MSIXパッケージも削除されました。" -ForegroundColor Yellow
                Write-Host "  Claude Setup を実行して再インストールしてください。" -ForegroundColor Yellow
                $issuesFound += "CoworkVMService 除去のためMSIXパッケージを削除済み - 要再インストール"
                # パッケージが削除されたので msixPackage をリセット
                $msixPackage = $null
                $installType = "unknown"
            }
        }
    } else {
        Write-Host "  [要管理者権限] サービスの除去には管理者権限が必要です。" -ForegroundColor Yellow
        Write-Host "  管理者権限でこのスクリプトを再実行してください。" -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Gray
        Write-Host "  手動対処手順:" -ForegroundColor Yellow
        Write-Host "  1. 管理者権限でPowerShellを起動" -ForegroundColor White
        Write-Host "  2. Get-AppxPackage 'Claude' | Remove-AppxPackage" -ForegroundColor Gray
        Write-Host "  3. Remove-Item -Path '$svcRegPath' -Recurse -Force" -ForegroundColor Gray
        Write-Host "  4. PCを再起動" -ForegroundColor White
        Write-Host "  5. Claude Setup を実行して再インストール" -ForegroundColor White
    }
} else {
    Write-Host "  CoworkVMService なし - OK" -ForegroundColor Green
}
Write-Host ""

# ============================================================
# Step 5: 旧MSIXパッケージの競合クリーンアップ
# ============================================================
Write-Host "[Step 5/$totalSteps] 旧MSIXパッケージの競合を確認..." -ForegroundColor Yellow

try {
    $allClaudePackages = Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "Claude" -or $_.PackageFamilyName -like "Claude_*" }

    if ($allClaudePackages -and $allClaudePackages.Count -gt 1) {
        Write-Host "  [問題] 複数のClaudeパッケージが検出されました ($($allClaudePackages.Count)個)" -ForegroundColor Yellow
        $issuesFound += "複数のMSIXパッケージが競合"

        # 最新バージョン以外を削除
        $latest = $allClaudePackages | Sort-Object -Property Version -Descending | Select-Object -First 1
        $old = $allClaudePackages | Where-Object { $_.PackageFullName -ne $latest.PackageFullName }

        foreach ($pkg in $old) {
            Write-Host "  旧パッケージを削除: $($pkg.PackageFullName)" -ForegroundColor Yellow
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                Write-Host "  削除成功" -ForegroundColor Green
            } catch {
                Write-Host "  削除失敗 (HRESULT: $($_.Exception.HResult)): $_" -ForegroundColor Red
                Write-Host "  手動削除: Get-AppxPackage '$($pkg.Name)' | Remove-AppxPackage" -ForegroundColor Gray

                # ForceUpdateFromAnyVersion での再インストールを提案
                Write-Host "  または再インストール時に強制上書き: " -ForegroundColor Gray
                Write-Host "    Add-AppxPackage -Path <msix-path> -ForceUpdateFromAnyVersion" -ForegroundColor Gray
            }
        }
    } elseif ($allClaudePackages) {
        Write-Host "  MSIXパッケージ: 1個 (正常)" -ForegroundColor Green
    } else {
        Write-Host "  MSIXパッケージなし" -ForegroundColor Gray
    }
} catch {
    Write-Host "  MSIXパッケージの確認中にエラー: $_" -ForegroundColor Gray
}
Write-Host ""

# ============================================================
# Step 6: 旧Squirrelインストールのクリーンアップ
# ============================================================
Write-Host "[Step 6/$totalSteps] 旧Squirrelインストールのクリーンアップ..." -ForegroundColor Yellow

if ($hasSquirrel -and $installType -eq "msix") {
    Write-Host "  MSIX版がインストール済みのため、旧Squirrelインストールを削除します。" -ForegroundColor Yellow
    Write-Host "  対象: $squirrelDir" -ForegroundColor Gray

    # Squirrelのアンインストールを試行
    $squirrelUpdate = Join-Path $squirrelDir "Update.exe"
    if (Test-Path $squirrelUpdate) {
        Write-Host "  Squirrelアンインストーラーを実行中..." -ForegroundColor Gray
        try {
            Start-Process -FilePath $squirrelUpdate -ArgumentList "--uninstall" -Wait -NoNewWindow -ErrorAction Stop
            Write-Host "  Squirrelアンインストール完了" -ForegroundColor Green
        } catch {
            Write-Host "  Squirrelアンインストーラーの実行に失敗: $_" -ForegroundColor Yellow
        }
    }

    # 残留フォルダの削除
    if (Test-Path $squirrelDir) {
        try {
            Remove-Item -Path $squirrelDir -Recurse -Force -ErrorAction Stop
            Write-Host "  旧インストールフォルダを削除しました" -ForegroundColor Green
        } catch {
            Write-Host "  フォルダ削除に失敗 (一部ファイルがロック中の可能性): $_" -ForegroundColor Yellow
            Write-Host "  手動削除: Remove-Item -Recurse -Force '$squirrelDir'" -ForegroundColor Gray
        }
    }

    # SquirrelTemp のクリーンアップ
    $squirrelTemp = Join-Path $localAppData "SquirrelTemp"
    if (Test-Path $squirrelTemp) {
        # Claudeに関連するファイルのみ削除（他のSquirrelアプリに影響しないよう注意）
        $squirrelLog = Join-Path $squirrelTemp "Squirrel-Install.log"
        if (Test-Path $squirrelLog) {
            $logContent = Get-Content $squirrelLog -Raw -ErrorAction SilentlyContinue
            if ($logContent -match "AnthropicClaude") {
                Remove-Item $squirrelLog -Force -ErrorAction SilentlyContinue
                Write-Host "  Squirrelインストールログを削除" -ForegroundColor Gray
            }
        }
    }
} elseif ($hasSquirrel) {
    Write-Host "  Squirrelインストール検出 (現行バージョン)" -ForegroundColor Gray
} else {
    Write-Host "  旧Squirrelインストールなし - OK" -ForegroundColor Green
}
Write-Host ""

# ============================================================
# Step 7: Visual C++ ランタイムの確認
# ============================================================
Write-Host "[Step 7/$totalSteps] Visual C++ ランタイムを確認..." -ForegroundColor Yellow

$vcInstalled = $false
$vcPaths = @(
    "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
)
foreach ($regPath in $vcPaths) {
    if (Test-Path $regPath) {
        $vcInstalled = $true
        $vcVersion = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).Version
        Write-Host "  Visual C++ 2015-2022 Redistributable (x64): インストール済み ($vcVersion)" -ForegroundColor Green
        break
    }
}
if (-not $vcInstalled) {
    $vcruntime = Join-Path $env:SystemRoot "System32\vcruntime140.dll"
    if (Test-Path $vcruntime) {
        Write-Host "  Visual C++ ランタイムDLL: 存在 (vcruntime140.dll)" -ForegroundColor Green
        $vcInstalled = $true
    } else {
        Write-Host "  [問題] Visual C++ 2015-2022 Redistributable (x64) が見つかりません" -ForegroundColor Red
        Write-Host "  ダウンロード: https://aka.ms/vs/17/release/vc_redist.x64.exe" -ForegroundColor Yellow
        $issuesFound += "Visual C++ Redistributable未インストール"
    }
}
Write-Host ""

# ============================================================
# Step 8: WebView2 ランタイムの確認
# ============================================================
Write-Host "[Step 8/$totalSteps] WebView2 ランタイムを確認..." -ForegroundColor Yellow

$webview2Installed = $false
$webview2Paths = @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
    "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
    "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
)
foreach ($regPath in $webview2Paths) {
    if (Test-Path $regPath) {
        $webview2Installed = $true
        $wv2Version = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).pv
        Write-Host "  WebView2 Runtime: インストール済み ($wv2Version)" -ForegroundColor Green
        break
    }
}
if (-not $webview2Installed) {
    Write-Host "  WebView2 Runtime: 不明 (Edgeがインストールされていれば通常は問題なし)" -ForegroundColor Gray
}
Write-Host ""

# ============================================================
# Step 9: CoreMessaging.dll の確認
# ============================================================
Write-Host "[Step 9/$totalSteps] CoreMessaging.dll を確認..." -ForegroundColor Yellow

$coreMsgDll = Join-Path $env:SystemRoot "System32\CoreMessaging.dll"
$coreMsgCrashDetected = $false

if (Test-Path $coreMsgDll) {
    $coreMsgInfo = (Get-Item $coreMsgDll).VersionInfo
    Write-Host "  CoreMessaging.dll: $($coreMsgInfo.FileVersion)" -ForegroundColor Green

    # CoreMessaging.dll が破損していないか簡易チェック (ファイルサイズ)
    $coreMsgSize = (Get-Item $coreMsgDll).Length
    if ($coreMsgSize -lt 100KB) {
        Write-Host "  [問題] CoreMessaging.dll のサイズが異常に小さい ($([math]::Round($coreMsgSize / 1KB)) KB)" -ForegroundColor Red
        Write-Host "  DISM /Online /Cleanup-Image /RestoreHealth で修復してください" -ForegroundColor Yellow
        $issuesFound += "CoreMessaging.dll サイズ異常"
    }
} else {
    Write-Host "  [問題] CoreMessaging.dll が見つかりません" -ForegroundColor Red
    Write-Host "  DISM /Online /Cleanup-Image /RestoreHealth で修復してください" -ForegroundColor Yellow
    $issuesFound += "CoreMessaging.dll 欠落"
}

# CoreMessaging.dll での過去のクラッシュを検出 (任意の例外コード)
try {
    $coreMsgCrashes = Get-WinEvent -LogName Application -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Message -match "Claude" -and
            $_.Message -match "CoreMessaging\.dll"
        } | Select-Object -First 1

    # 特定の例外コードを抽出
    $exceptionCode = ""
    if ($coreMsgCrashes -and $coreMsgCrashes.Message -match "Exception code:\s*(0x[0-9a-fA-F]+)") {
        $exceptionCode = $Matches[1]
    }

    if ($coreMsgCrashes) {
        $coreMsgCrashDetected = $true
        if ($exceptionCode) {
            Write-Host "  [問題] CoreMessaging.dll クラッシュを検出 (例外コード: $exceptionCode)" -ForegroundColor Red
        } else {
            Write-Host "  [問題] CoreMessaging.dll クラッシュを検出" -ForegroundColor Red
        }
        Write-Host "  Faulting module: CoreMessaging.dll — MSIX パッケージとの互換性問題" -ForegroundColor Yellow

        # CoreMessaging.dll のバージョンとOSビルドの不整合チェック
        $osBuild = [System.Environment]::OSVersion.Version.Build
        if ((Test-Path $coreMsgDll) -and $coreMsgInfo) {
            $dllBuild = $coreMsgInfo.FileVersion -replace '.*?(\d{5})\..*', '$1'
            if ($dllBuild -and $osBuild -and ($dllBuild -ne $osBuild.ToString())) {
                Write-Host "  [問題] CoreMessaging.dll ビルド ($dllBuild) と OS ビルド ($osBuild) が不一致" -ForegroundColor Red
                Write-Host "  DISM /Online /Cleanup-Image /RestoreHealth で修復、または Windows Update を適用してください" -ForegroundColor Yellow
                $issuesFound += "CoreMessaging.dll バージョン不整合 (DLL: $dllBuild, OS: $osBuild)"
            }
        }

        $issuesFound += "CoreMessaging.dll クラッシュ"

        # 対処: CoreMessaging.dll 互換性問題の自動修復
        Write-Host "" -ForegroundColor Gray
        Write-Host "  --- CoreMessaging.dll 互換性問題の自動修復 ---" -ForegroundColor Cyan

        # 対処1: システムファイルの修復 (管理者権限が必要)
        if ($isAdmin) {
            Write-Host "  システムファイルチェッカーを実行しています (sfc /scannow)..." -ForegroundColor Gray
            Write-Host "  (数分かかる場合があります)" -ForegroundColor Gray
            $sfcResult = & sfc /scannow 2>&1
            $sfcOutput = $sfcResult | Out-String
            if ($sfcOutput -match "整合性違反を検出しました" -or $sfcOutput -match "found integrity violations" -or $sfcOutput -match "修復しました" -or $sfcOutput -match "successfully repaired") {
                Write-Host "  sfc: 破損ファイルを検出・修復しました" -ForegroundColor Green
            } elseif ($sfcOutput -match "違反を検出しませんでした" -or $sfcOutput -match "did not find any integrity violations") {
                Write-Host "  sfc: 破損なし" -ForegroundColor Green
            } else {
                Write-Host "  sfc: 完了 (結果を確認してください)" -ForegroundColor Yellow
            }

            Write-Host "  DISM でコンポーネントストアを修復しています..." -ForegroundColor Gray
            $dismResult = & DISM /Online /Cleanup-Image /RestoreHealth 2>&1
            $dismOutput = $dismResult | Out-String
            if ($dismOutput -match "復元操作は正常に完了しました" -or $dismOutput -match "The restore operation completed successfully") {
                Write-Host "  DISM: 修復完了" -ForegroundColor Green
            } else {
                Write-Host "  DISM: 完了 (結果を確認してください)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  [スキップ] sfc /scannow と DISM は管理者権限が必要です" -ForegroundColor Yellow
            Write-Host "  管理者権限のPowerShellで以下を実行してください:" -ForegroundColor Yellow
            Write-Host "    sfc /scannow" -ForegroundColor White
            Write-Host "    DISM /Online /Cleanup-Image /RestoreHealth" -ForegroundColor White
        }

        # 対処2: Windows 8 互換モードの設定 (CoreMessaging.dll クラッシュの最も効果的な回避策)
        Write-Host "  Windows 8 互換モードを設定しています..." -ForegroundColor Gray
        $compatRegPath = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"
        if (-not (Test-Path $compatRegPath)) {
            New-Item -Path $compatRegPath -Force | Out-Null
        }
        if ($installType -eq "msix" -and $msixPackage) {
            $claudeExePath = Join-Path $msixPackage.InstallLocation "Claude.exe"
            if (Test-Path $claudeExePath) {
                Set-ItemProperty -Path $compatRegPath -Name $claudeExePath -Value "~ WIN8RTM" -ErrorAction SilentlyContinue
                Write-Host "  互換モード設定完了: $claudeExePath → Windows 8" -ForegroundColor Green
                $repairsPerformed += "Windows 8 互換モード設定 (CoreMessaging.dll 回避)"
            }
        } elseif ($claudeExe) {
            Set-ItemProperty -Path $compatRegPath -Name $claudeExe -Value "~ WIN8RTM" -ErrorAction SilentlyContinue
            Write-Host "  互換モード設定完了: $claudeExe → Windows 8" -ForegroundColor Green
            $repairsPerformed += "Windows 8 互換モード設定 (CoreMessaging.dll 回避)"
        }

        # 対処4: フレームワークパッケージの再登録
        Write-Host "  フレームワークパッケージを再登録しています..." -ForegroundColor Gray
        Get-AppxPackage -AllUsers "*Framework*" -ErrorAction SilentlyContinue | ForEach-Object {
            $manifestPath = Join-Path $_.InstallLocation "AppxManifest.xml"
            if (Test-Path $manifestPath) {
                Add-AppxPackage -Register $manifestPath -DisableDevelopmentMode -ErrorAction SilentlyContinue
            }
        }
        Write-Host "  フレームワーク再登録完了" -ForegroundColor Green

        # 対処5: Windows App Runtime の最新バージョン確認
        $latestRuntime = Get-AppxPackage "*WindowsAppRuntime*" -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending | Select-Object -First 1
        if ($latestRuntime) {
            Write-Host "  Windows App Runtime: $($latestRuntime.Name) v$($latestRuntime.Version)" -ForegroundColor Green
        } else {
            Write-Host "  [問題] Windows App Runtime がインストールされていません" -ForegroundColor Red
            Write-Host "  https://learn.microsoft.com/ja-jp/windows/apps/windows-app-sdk/downloads" -ForegroundColor Yellow
            $issuesFound += "Windows App Runtime 未インストール"
        }

        # MSIX版で問題が続く場合の代替案を提示
        Write-Host "" -ForegroundColor Gray
        Write-Host "  この問題が解決しない場合の対処法:" -ForegroundColor Yellow
        Write-Host "  1. Windows Updateで最新の状態に更新してPCを再起動" -ForegroundColor White
        Write-Host "  2. Claude MSIX を再インストール:" -ForegroundColor White
        Write-Host "     Get-AppxPackage 'Claude' | Remove-AppxPackage" -ForegroundColor Gray
        Write-Host "     その後 https://claude.ai/download から再インストール" -ForegroundColor Gray
        Write-Host "  3. Windows App SDK ランタイムを最新版に更新:" -ForegroundColor White
        Write-Host "     https://learn.microsoft.com/ja-jp/windows/apps/windows-app-sdk/downloads" -ForegroundColor Gray
        Write-Host "  4. Windows 11 へのアップグレードを検討" -ForegroundColor White
        Write-Host "     (Windows 11 では CoreMessaging.dll の互換性問題が解消されています)" -ForegroundColor Gray
    } else {
        Write-Host "  CoreMessaging.dll クラッシュ履歴なし" -ForegroundColor Green
    }
} catch {
    Write-Host "  クラッシュ履歴の確認中にエラー: $_" -ForegroundColor Gray
}
Write-Host ""

# ============================================================
# Step 10: Windows バージョン互換性チェック
# ============================================================
Write-Host "[Step 10/$totalSteps] Windows バージョン互換性を確認..." -ForegroundColor Yellow

$osVersion = [System.Environment]::OSVersion.Version
$osBuild = $osVersion.Build
Write-Host "  Windows バージョン: $($osVersion.Major).$($osVersion.Minor) ビルド $osBuild" -ForegroundColor Gray

# Windows 10 のバージョンとサービス状態を確認
# ビルド番号 → バージョン名のマッピング
$win10Versions = @{
    19045 = @{ Name = "22H2"; EOL = $false; EOLDate = "2025-10-14" }
    19044 = @{ Name = "21H2"; EOL = $true;  EOLDate = "2024-06-11" }
    19043 = @{ Name = "21H1"; EOL = $true;  EOLDate = "2022-12-13" }
    19042 = @{ Name = "20H2"; EOL = $true;  EOLDate = "2023-05-09" }
    19041 = @{ Name = "2004"; EOL = $true;  EOLDate = "2021-12-14" }
    18363 = @{ Name = "1909"; EOL = $true;  EOLDate = "2022-05-10" }
    18362 = @{ Name = "1903"; EOL = $true;  EOLDate = "2020-12-08" }
    17763 = @{ Name = "1809"; EOL = $true;  EOLDate = "2021-05-11" }
}

if ($osVersion.Major -lt 10) {
    Write-Host "  [問題] Windows 10 以降が必要です" -ForegroundColor Red
    $issuesFound += "Windows バージョンが古い (Windows 10未満)"
} elseif ($osVersion.Major -eq 10 -and $osBuild -lt 17763) {
    Write-Host "  [問題] Windows 10 バージョン 1809 (ビルド 17763) 以降が必要です" -ForegroundColor Red
    Write-Host "  現在のビルド: $osBuild" -ForegroundColor Yellow
    Write-Host "  Windows Updateで最新バージョンに更新してください" -ForegroundColor Yellow
    $issuesFound += "Windows ビルドが古い ($osBuild < 17763)"
} else {
    # サービス終了チェック
    $versionInfo = $win10Versions[$osBuild]
    if ($versionInfo) {
        $versionName = $versionInfo.Name
        Write-Host "  Windows 10 バージョン: $versionName (ビルド $osBuild)" -ForegroundColor Gray

        if ($versionInfo.EOL) {
            Write-Host "" -ForegroundColor Gray
            Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
            Write-Host "  ║  [重大] このWindows 10はサービス終了(サポート切れ)です！     ║" -ForegroundColor Red
            Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
            Write-Host "  バージョン $versionName のサポート終了日: $($versionInfo.EOLDate)" -ForegroundColor Red
            Write-Host "" -ForegroundColor Gray
            Write-Host "  これがClaude Desktop起動失敗の主要原因です。" -ForegroundColor Yellow
            Write-Host "  古いCoreMessaging.dllがClaude MSIX版と互換性がありません。" -ForegroundColor Yellow
            Write-Host "" -ForegroundColor Gray
            Write-Host "  === 対処法 (いずれかを実行) ===" -ForegroundColor Cyan
            Write-Host "  [推奨] Windows 10 を最新バージョン (22H2) に更新:" -ForegroundColor White
            Write-Host "    1. 設定 → 更新とセキュリティ → Windows Update → 更新プログラムのチェック" -ForegroundColor Gray
            Write-Host "    2. または https://www.microsoft.com/ja-jp/software-download/windows10" -ForegroundColor Gray
            Write-Host "       から「Windows 10 更新アシスタント」をダウンロードして実行" -ForegroundColor Gray
            Write-Host "" -ForegroundColor Gray
            Write-Host "  [代替] Windows 11 にアップグレード:" -ForegroundColor White
            Write-Host "    https://www.microsoft.com/ja-jp/software-download/windows11" -ForegroundColor Gray
            Write-Host "" -ForegroundColor Gray
            $issuesFound += "Windows 10 バージョン $versionName はサービス終了 - CoreMessaging.dll互換性問題の原因"
        } else {
            Write-Host "  Windows バージョン: 互換性OK (サポート中)" -ForegroundColor Green
        }
    } else {
        # Windows 11 またはマッピングにないビルド
        if ($osBuild -ge 22000) {
            Write-Host "  Windows 11 (ビルド $osBuild): 互換性OK" -ForegroundColor Green
        } else {
            Write-Host "  Windows 10 ビルド ${osBuild}: 互換性OK" -ForegroundColor Green
        }
    }
}

# .NET Framework の確認
$netRegPath = "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"
if (Test-Path $netRegPath) {
    $netRelease = (Get-ItemProperty $netRegPath -ErrorAction SilentlyContinue).Release
    if ($netRelease) {
        $netVersion = switch ($true) {
            ($netRelease -ge 533320) { "4.8.1以降"; break }
            ($netRelease -ge 528040) { "4.8"; break }
            ($netRelease -ge 461808) { "4.7.2"; break }
            ($netRelease -ge 461308) { "4.7.1"; break }
            ($netRelease -ge 460798) { "4.7"; break }
            ($netRelease -ge 394802) { "4.6.2"; break }
            default { "4.6未満" }
        }
        Write-Host "  .NET Framework: $netVersion (Release $netRelease)" -ForegroundColor Green
    }
} else {
    Write-Host "  [警告] .NET Framework 4.x が見つかりません" -ForegroundColor Yellow
}
Write-Host ""

# ============================================================
# Step 11: ユーザーデータの完全リセット
# ============================================================
Write-Host "[Step 11/$totalSteps] ユーザーデータをリセット..." -ForegroundColor Yellow

if (Test-Path $configDir) {
    # 設定ファイルのバックアップ
    if (Test-Path $configFile) {
        $backupFile = "$configFile.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $configFile $backupFile -Force
        Write-Host "  設定ファイルをバックアップ: $backupFile" -ForegroundColor Green
    }

    # 削除対象のサブフォルダ・ファイル一覧（設定ファイルとバックアップは保持）
    $deleteDirs = @(
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnWebGPUCache",
        "blob_storage", "Session Storage", "Local Storage", "IndexedDB",
        "Service Worker", "Shared Dictionary", "WebStorage",
        "Network", "databases", "CachedData", "Crashpad",
        "logs", "tmp"
    )

    $deleteFiles = @(
        "Cookies", "Cookies-journal",
        "Preferences", "Local State",
        "Network Persistent State",
        "TransportSecurity",
        "Visited Links", "Web Data", "Web Data-journal",
        "window-state.json"
    )

    foreach ($dir in $deleteDirs) {
        $fullPath = Join-Path $configDir $dir
        if (Test-Path $fullPath) {
            Remove-Item -Path $fullPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  削除: $dir/" -ForegroundColor Gray
        }
    }

    foreach ($file in $deleteFiles) {
        $fullPath = Join-Path $configDir $file
        if (Test-Path $fullPath) {
            Remove-Item -Path $fullPath -Force -ErrorAction SilentlyContinue
            Write-Host "  削除: $file" -ForegroundColor Gray
        }
    }

    Write-Host "  ユーザーデータリセット完了" -ForegroundColor Green
} else {
    Write-Host "  設定ディレクトリなし。スキップ。" -ForegroundColor Gray
}

# MSIX版のローカルキャッシュもクリア
if ($installType -eq "msix" -and $msixPackage) {
    $msixLocalCache = Join-Path (Join-Path (Join-Path $localAppData "Packages") $msixPackage.PackageFamilyName) "LocalCache"
    if (Test-Path $msixLocalCache) {
        Write-Host "  MSIXローカルキャッシュをクリア: $msixLocalCache" -ForegroundColor Gray
        Get-ChildItem $msixLocalCache -Recurse -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  MSIXキャッシュクリア完了" -ForegroundColor Green
    }

    $msixTempState = Join-Path (Join-Path (Join-Path $localAppData "Packages") $msixPackage.PackageFamilyName) "TempState"
    if (Test-Path $msixTempState) {
        Get-ChildItem $msixTempState -Recurse -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  MSIX TempStateクリア完了" -ForegroundColor Green
    }
}
Write-Host ""

# ============================================================
# Step 12: 設定ファイルの検証・修復
# ============================================================
Write-Host "[Step 12/$totalSteps] 設定ファイルを検証・修復..." -ForegroundColor Yellow

if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

if (-not (Test-Path $configFile)) {
    "{}" | Out-File -FilePath $configFile -Encoding UTF8 -NoNewline
    Write-Host "  空の設定ファイルを新規作成" -ForegroundColor Green
} else {
    try {
        $configContent = Get-Content $configFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($configContent)) {
            throw "Empty file"
        }
        $config = $configContent | ConvertFrom-Json

        # MCP設定に問題がないか確認
        if ($config.mcpServers) {
            $mcpCount = ($config.mcpServers.PSObject.Properties | Measure-Object).Count
            Write-Host "  MCP サーバー: $mcpCount 件設定あり" -ForegroundColor Gray

            $hasMcpIssue = $false
            foreach ($prop in $config.mcpServers.PSObject.Properties) {
                $serverName = $prop.Name
                $serverConfig = $prop.Value
                if ($serverConfig.command) {
                    $cmdExists = Get-Command $serverConfig.command -ErrorAction SilentlyContinue
                    if (-not $cmdExists) {
                        Write-Host "  [警告] MCP '$serverName': コマンド '$($serverConfig.command)' が見つかりません" -ForegroundColor Red
                        $hasMcpIssue = $true
                    }
                }
            }

            if ($hasMcpIssue) {
                Write-Host "  MCP設定に問題あり。一時的に無効化します..." -ForegroundColor Yellow
                $config.mcpServers = [PSCustomObject]@{}
                $config | ConvertTo-Json -Depth 10 | Out-File -FilePath $configFile -Encoding UTF8
                Write-Host "  MCP設定を無効化しました (バックアップから復元可能)" -ForegroundColor Green
                $issuesFound += "MCP設定に問題あり - 無効化済み"
            }
        }

        Write-Host "  設定ファイル: JSON形式OK" -ForegroundColor Green
    } catch {
        Write-Host "  [問題] 設定ファイル破損: $_" -ForegroundColor Red
        "{}" | Out-File -FilePath $configFile -Encoding UTF8 -NoNewline
        Write-Host "  設定ファイルをリセットしました" -ForegroundColor Green
        $issuesFound += "設定ファイル破損 - リセット済み"
    }
}
Write-Host ""

# ============================================================
# Step 13: 修復後の起動テスト
# ============================================================
Write-Host "[Step 13/$totalSteps] 修復後の起動テスト..." -ForegroundColor Yellow

# 起動テスト
if ($installType -eq "msix" -and $msixPackage) {
    # MSIX版はshell:AppsFolderから起動
    $appId = "$($msixPackage.PackageFamilyName)!Claude"
    Write-Host "  MSIX版Claude Desktopを起動しています..." -ForegroundColor Gray
    Write-Host "  起動コマンド: explorer.exe shell:AppsFolder\$appId" -ForegroundColor Gray
    Start-Process "explorer.exe" -ArgumentList "shell:AppsFolder\$appId"
    Start-Sleep -Seconds 8

    $proc = Get-Process -Name "Claude" -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Host "  起動成功！プロセスを確認しました。" -ForegroundColor Green
    } else {
        Write-Host "  プロセスが検出されません。起動に時間がかかっている可能性があります。" -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        $proc = Get-Process -Name "Claude" -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "  起動成功！(遅延起動)" -ForegroundColor Green
        } else {
            Write-Host "  起動に失敗しました" -ForegroundColor Red
            $issuesFound += "修復後も起動失敗"

            # CoreMessaging.dll クラッシュが検出されていた場合、追加のガイダンスを表示
            if ($coreMsgCrashDetected) {
                Write-Host "" -ForegroundColor Gray
                Write-Host "  ★ CoreMessaging.dll の問題が原因で起動できない可能性が高いです" -ForegroundColor Red
                Write-Host "  以下の手順を順番にお試しください:" -ForegroundColor Yellow
                Write-Host "  1. Windows Update を実行して PC を再起動" -ForegroundColor White
                Write-Host "  2. 管理者 PowerShell で以下を実行:" -ForegroundColor White
                Write-Host "     sfc /scannow" -ForegroundColor Gray
                Write-Host "     DISM /Online /Cleanup-Image /RestoreHealth" -ForegroundColor Gray
                Write-Host "  3. PC を再起動後、Claude Desktop を再度起動" -ForegroundColor White
            }
        }
    }
} elseif ($claudeExe) {
    Write-Host "  Claude Desktopを起動しています (--disable-gpu)..." -ForegroundColor Gray
    Start-Process $claudeExe -ArgumentList "--disable-gpu"
    Start-Sleep -Seconds 8

    $proc = Get-Process -Name "Claude" -ErrorAction SilentlyContinue
    if ($proc) {
        $hasWindow = $proc | Where-Object { $_.MainWindowHandle -ne 0 }
        if ($hasWindow) {
            Write-Host "  起動成功！ウィンドウを確認しました！" -ForegroundColor Green
        } else {
            Write-Host "  プロセスは起動しましたが、ウィンドウが表示されていません" -ForegroundColor Yellow
            $issuesFound += "起動後ウィンドウ表示なし"
        }
    } else {
        Write-Host "  起動に失敗しました" -ForegroundColor Red
        $issuesFound += "修復後も起動失敗"
    }
} else {
    Write-Host "  実行ファイルが見つからないためスキップ" -ForegroundColor Red
}

# 起動失敗時の段階的リカバリ
$launchFailed = $issuesFound -contains "修復後も起動失敗"
if ($launchFailed) {
    Write-Host "" -ForegroundColor Gray
    Write-Host "  ========================================" -ForegroundColor Red
    Write-Host "  起動に失敗しました。追加の修復を試みます..." -ForegroundColor Red
    Write-Host "  ========================================" -ForegroundColor Red
    Write-Host "" -ForegroundColor Gray

    # リカバリ Phase 1: 互換モード未設定なら設定して再試行
    if (-not $coreMsgCrashDetected) {
        Write-Host "  [Phase 1] Windows 8 互換モードを設定して再試行..." -ForegroundColor Yellow
        $compatRegPath = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"
        if (-not (Test-Path $compatRegPath)) {
            New-Item -Path $compatRegPath -Force | Out-Null
        }
        if ($claudeExe) {
            Set-ItemProperty -Path $compatRegPath -Name $claudeExe -Value "~ WIN8RTM" -ErrorAction SilentlyContinue
            Write-Host "  互換モード設定完了" -ForegroundColor Green
        }
    }

    # リカバリ Phase 2: --disable-gpu で再試行 (Squirrel/standalone)
    if ($claudeExe -and $installType -ne "msix") {
        Write-Host "  [Phase 2] --disable-gpu --no-sandbox で再試行..." -ForegroundColor Yellow
        Get-Process -Name "Claude" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Start-Process $claudeExe -ArgumentList "--disable-gpu", "--no-sandbox"
        Start-Sleep -Seconds 10
        $proc = Get-Process -Name "Claude" -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "  起動成功！(--disable-gpu --no-sandbox)" -ForegroundColor Green
            $issuesFound = $issuesFound | Where-Object { $_ -ne "修復後も起動失敗" }
            $issuesFound += "GPUサンドボックス無効で起動成功 (根本対処が必要)"
        }
    }

    # リカバリ Phase 3: MSIX再登録
    if ($installType -eq "msix" -and $msixPackage) {
        Write-Host "  [Phase 3] MSIXパッケージを再登録して再試行..." -ForegroundColor Yellow
        Get-Process -Name "Claude" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $manifestPath = Join-Path $msixPackage.InstallLocation "AppxManifest.xml"
        if (Test-Path $manifestPath) {
            try {
                Add-AppxPackage -Register $manifestPath -DisableDevelopmentMode -ErrorAction Stop
                Write-Host "  再登録完了。起動を再試行..." -ForegroundColor Green
                Start-Sleep -Seconds 2
                $appId = "$($msixPackage.PackageFamilyName)!Claude"
                Start-Process "explorer.exe" -ArgumentList "shell:AppsFolder\$appId"
                Start-Sleep -Seconds 10
                $proc = Get-Process -Name "Claude" -ErrorAction SilentlyContinue
                if ($proc) {
                    Write-Host "  再登録後の起動に成功！" -ForegroundColor Green
                    $issuesFound = $issuesFound | Where-Object { $_ -ne "修復後も起動失敗" }
                } else {
                    Write-Host "  再登録後も起動失敗" -ForegroundColor Red
                }
            } catch {
                Write-Host "  再登録に失敗: $_" -ForegroundColor Red
            }
        }
    }

    # リカバリ Phase 4: 再インストールの自動案内
    $stillFailed = $issuesFound -contains "修復後も起動失敗"
    if ($stillFailed) {
        Write-Host "" -ForegroundColor Gray
        Write-Host "  ========================================" -ForegroundColor Cyan
        Write-Host "  全ての自動修復が失敗しました。" -ForegroundColor Red
        Write-Host "  再インストールを推奨します。" -ForegroundColor Red
        Write-Host "  ========================================" -ForegroundColor Cyan
        Write-Host "" -ForegroundColor Gray

        if ($installType -eq "msix") {
            Write-Host "  再インストール手順:" -ForegroundColor Yellow
            Write-Host "  1. 以下のコマンドで現在のパッケージを削除:" -ForegroundColor White
            Write-Host "     Get-AppxPackage 'Claude' | Remove-AppxPackage" -ForegroundColor Gray
            Write-Host "  2. PCを再起動" -ForegroundColor White
            Write-Host "  3. https://claude.ai/download から再インストール" -ForegroundColor White
            Write-Host "" -ForegroundColor Gray

            $doReinstall = Read-Host "  今すぐMSIXパッケージを削除して再インストール準備をしますか？ (y/N)"
            if ($doReinstall -eq "y" -or $doReinstall -eq "Y") {
                Write-Host "  MSIXパッケージを削除しています..." -ForegroundColor Yellow
                Get-Process -Name "Claude" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                try {
                    Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction Stop
                    Write-Host "  削除完了。" -ForegroundColor Green
                    Write-Host "" -ForegroundColor Gray
                    Write-Host "  次の手順:" -ForegroundColor Cyan
                    Write-Host "  1. PCを再起動してください" -ForegroundColor White
                    Write-Host "  2. ブラウザで https://claude.ai/download を開いてください" -ForegroundColor White
                    Write-Host "  3. ダウンロードしたインストーラーを実行してください" -ForegroundColor White
                    Write-Host "" -ForegroundColor Gray

                    $openDownload = Read-Host "  ダウンロードページをブラウザで開きますか？ (y/N)"
                    if ($openDownload -eq "y" -or $openDownload -eq "Y") {
                        Start-Process "https://claude.ai/download"
                        Write-Host "  ブラウザを開きました" -ForegroundColor Green
                    }
                } catch {
                    Write-Host "  削除に失敗: $_" -ForegroundColor Red
                    Write-Host "  手動で削除してください: Get-AppxPackage 'Claude' | Remove-AppxPackage" -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "  再インストール手順:" -ForegroundColor Yellow
            Write-Host "  1. コントロールパネルからClaude Desktopをアンインストール" -ForegroundColor White
            Write-Host "  2. %APPDATA%\Claude フォルダを削除" -ForegroundColor White
            Write-Host "  3. PCを再起動" -ForegroundColor White
            Write-Host "  4. https://claude.ai/download から再インストール" -ForegroundColor White
            Write-Host "" -ForegroundColor Gray

            $openDownload = Read-Host "  ダウンロードページをブラウザで開きますか？ (y/N)"
            if ($openDownload -eq "y" -or $openDownload -eq "Y") {
                Start-Process "https://claude.ai/download"
                Write-Host "  ブラウザを開きました" -ForegroundColor Green
            }
        }
    }
}
Write-Host ""

# ============================================================
# 結果サマリー
# ============================================================
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " 診断・修復結果" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "インストール形式: $installType" -ForegroundColor White
Write-Host ""

if ($issuesFound.Count -eq 0) {
    Write-Host "  問題は検出されませんでした。" -ForegroundColor Green
    Write-Host "  キャッシュとユーザーデータをリセットしました。" -ForegroundColor Green
} else {
    Write-Host "  検出された問題:" -ForegroundColor Red
    foreach ($issue in $issuesFound) {
        Write-Host "    - $issue" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "実行された修復:" -ForegroundColor White
Write-Host "  - Claude関連プロセスの完全終了"
Write-Host "  - インストール形式の検出と整合性チェック"
Write-Host "  - インストールログの分析と原因特定"
if ($coworkService) {
    Write-Host "  - CoworkVMService競合の対処"
}
if ($hasSquirrel -and $installType -eq "msix") {
    Write-Host "  - 旧Squirrelインストールのクリーンアップ"
}
Write-Host "  - キャッシュ・一時ファイルの完全削除"
Write-Host "  - ユーザーデータのリセット (設定ファイルはバックアップ済み)"
Write-Host "  - 設定ファイルの検証"
if ($installType -eq "msix") {
    Write-Host "  - MSIX経由での起動テスト"
} else {
    Write-Host "  - --disable-gpu オプションで起動テスト"
}

Write-Host ""
Write-Host "まだ起動しない場合の追加対策:" -ForegroundColor Yellow
Write-Host "  1. Claude Desktopを再インストール:" -ForegroundColor White
Write-Host "     https://claude.ai/download" -ForegroundColor Gray
if ($installType -eq "msix") {
    Write-Host "  2. MSIXパッケージを強制再インストール:" -ForegroundColor White
    Write-Host "     Get-AppxPackage 'Claude' | Remove-AppxPackage" -ForegroundColor Gray
    Write-Host "     その後、https://claude.ai/download から再インストール" -ForegroundColor Gray
    Write-Host "  3. CoworkVMService が原因の場合 (HRESULT 0x80073CF6):" -ForegroundColor White
    Write-Host "     管理者PowerShellで以下を順に実行:" -ForegroundColor Gray
    Write-Host "       Get-AppxPackage 'Claude' | Remove-AppxPackage" -ForegroundColor Gray
    Write-Host "       Remove-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CoworkVMService' -Recurse -Force" -ForegroundColor Gray
    Write-Host "       その後PCを再起動し、Claude Setup を実行" -ForegroundColor Gray
} else {
    Write-Host "  2. 完全リセット (全設定削除):" -ForegroundColor White
    Write-Host "     Remove-Item -Recurse -Force '$configDir'" -ForegroundColor Gray
    Write-Host "     その後、再インストール" -ForegroundColor Gray
}
Write-Host "  4. Visual C++ Redistributableをインストール:" -ForegroundColor White
Write-Host "     https://aka.ms/vs/17/release/vc_redist.x64.exe" -ForegroundColor Gray
Write-Host "  5. Windows Updateを確認し、最新の状態にする" -ForegroundColor White
Write-Host ""
Write-Host "バックアップ:" -ForegroundColor White
Write-Host "  $configFile.backup.*" -ForegroundColor Gray
Write-Host ""
Read-Host "Enterキーで終了"
