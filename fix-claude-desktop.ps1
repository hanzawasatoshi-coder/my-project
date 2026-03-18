#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Desktop 起動エラー修正スクリプト (PowerShell版)
.DESCRIPTION
    "Claude Desktop failed to Launch" エラーを修正します。
    - プロセス完全終了
    - ユーザーデータの完全リセット
    - 設定ファイルの検証・修復
    - Visual C++ ランタイム確認
    - WebView2ランタイム確認
    - キャッシュ・一時ファイルのクリア
    - アプリ整合性チェック
    - ログの確認
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Claude Desktop 起動エラー修正ツール" -ForegroundColor Cyan
Write-Host " 対象: 'Claude Desktop failed to Launch'" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$configDir = Join-Path $env:APPDATA "Claude"
$configFile = Join-Path $configDir "claude_desktop_config.json"
$localAppData = $env:LOCALAPPDATA
$issuesFound = @()

# ============================================================
# Step 1: Claude関連プロセスの完全終了
# ============================================================
Write-Host "[Step 1/8] Claude関連プロセスを完全終了..." -ForegroundColor Yellow

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
# Step 2: インストール状態の確認
# ============================================================
Write-Host "[Step 2/8] インストール状態を確認..." -ForegroundColor Yellow

# インストールパスの検出
$possiblePaths = @(
    (Join-Path $localAppData "Programs\claude\Claude.exe"),
    (Join-Path $localAppData "Programs\Claude\Claude.exe"),
    (Join-Path $localAppData "Claude\Claude.exe"),
    (Join-Path $env:ProgramFiles "Claude\Claude.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Claude\Claude.exe")
)

$claudeExe = $null
foreach ($p in $possiblePaths) {
    if (Test-Path $p) {
        $claudeExe = $p
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
                    break
                }
            } catch {}
        }
    }
}

if ($claudeExe) {
    $fileInfo = Get-Item $claudeExe
    Write-Host "  実行ファイル: $claudeExe" -ForegroundColor Green
    Write-Host "  バージョン: $($fileInfo.VersionInfo.FileVersion)" -ForegroundColor Gray
    Write-Host "  サイズ: $([math]::Round($fileInfo.Length / 1MB, 1)) MB" -ForegroundColor Gray
    Write-Host "  更新日: $($fileInfo.LastWriteTime)" -ForegroundColor Gray

    # アプリのresourcesフォルダ確認
    $appDir = Split-Path $claudeExe
    $resourcesDir = Join-Path $appDir "resources"
    $appAsar = Join-Path $resourcesDir "app.asar"

    if (-not (Test-Path $appAsar)) {
        Write-Host "  [問題] app.asarが見つかりません。インストールが破損しています。" -ForegroundColor Red
        $issuesFound += "app.asar missing - インストール破損"
    } else {
        $asarSize = (Get-Item $appAsar).Length
        if ($asarSize -lt 1MB) {
            Write-Host "  [問題] app.asarのサイズが異常に小さい ($([math]::Round($asarSize / 1KB)) KB)" -ForegroundColor Red
            $issuesFound += "app.asar too small - インストール破損の可能性"
        } else {
            Write-Host "  app.asar: OK ($([math]::Round($asarSize / 1MB, 1)) MB)" -ForegroundColor Green
        }
    }
} else {
    Write-Host "  [問題] Claude Desktopの実行ファイルが見つかりません" -ForegroundColor Red
    $issuesFound += "Claude Desktop実行ファイルが見つからない"
}
Write-Host ""

# ============================================================
# Step 3: Visual C++ ランタイムの確認
# ============================================================
Write-Host "[Step 3/8] Visual C++ ランタイムを確認..." -ForegroundColor Yellow

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
    # DLLの直接チェック
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
# Step 4: WebView2 ランタイムの確認
# ============================================================
Write-Host "[Step 4/8] WebView2 ランタイムを確認..." -ForegroundColor Yellow

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
# Step 5: ユーザーデータの完全リセット
# ============================================================
Write-Host "[Step 5/8] ユーザーデータをリセット..." -ForegroundColor Yellow

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
Write-Host ""

# ============================================================
# Step 6: 設定ファイルの検証・修復
# ============================================================
Write-Host "[Step 6/8] 設定ファイルを検証・修復..." -ForegroundColor Yellow

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
# Step 7: Windowsイベントログの確認
# ============================================================
Write-Host "[Step 7/8] Windowsイベントログからエラーを検索..." -ForegroundColor Yellow

try {
    $events = Get-WinEvent -LogName Application -MaxEvents 50 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Message -match "Claude" -and $_.Level -le 2
        } | Select-Object -First 5

    if ($events) {
        Write-Host "  Claude関連のエラーイベント:" -ForegroundColor Red
        foreach ($evt in $events) {
            $msg = $evt.Message
            if ($msg.Length -gt 150) { $msg = $msg.Substring(0, 150) + "..." }
            Write-Host "  [$($evt.TimeCreated)] $msg" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  Claude関連のエラーイベントなし" -ForegroundColor Green
    }
} catch {
    Write-Host "  イベントログの読み取りに失敗: $_" -ForegroundColor Gray
}
Write-Host ""

# ============================================================
# Step 8: 修復後の起動テスト
# ============================================================
Write-Host "[Step 8/8] 修復後の起動テスト..." -ForegroundColor Yellow

if ($claudeExe) {
    Write-Host "  Claude Desktopを起動しています..." -ForegroundColor Gray

    # まず --disable-gpu で試行（GPU関連のクラッシュを回避）
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
Write-Host ""

# ============================================================
# 結果サマリー
# ============================================================
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " 診断・修復結果" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
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
Write-Host "  - キャッシュ・一時ファイルの完全削除"
Write-Host "  - ユーザーデータのリセット (設定ファイルはバックアップ済み)"
Write-Host "  - 設定ファイルの検証"
Write-Host "  - --disable-gpu オプションで起動テスト"

Write-Host ""
Write-Host "まだ起動しない場合の追加対策:" -ForegroundColor Yellow
Write-Host "  1. Claude Desktopを再インストール:" -ForegroundColor White
Write-Host "     https://claude.ai/download" -ForegroundColor Gray
Write-Host "  2. 完全リセット (全設定削除):" -ForegroundColor White
Write-Host "     Remove-Item -Recurse -Force '$configDir'" -ForegroundColor Gray
Write-Host "     その後、再インストール" -ForegroundColor Gray
Write-Host "  3. Visual C++ Redistributableをインストール:" -ForegroundColor White
Write-Host "     https://aka.ms/vs/17/release/vc_redist.x64.exe" -ForegroundColor Gray
Write-Host "  4. Windows Updateを確認し、最新の状態にする" -ForegroundColor White
Write-Host ""
Write-Host "バックアップ:" -ForegroundColor White
Write-Host "  $configFile.backup.*" -ForegroundColor Gray
Write-Host ""
Read-Host "Enterキーで終了"
