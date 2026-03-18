#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Desktop 起動エラー修正スクリプト (PowerShell版)
.DESCRIPTION
    Claude Desktopが起動時にエラーを表示する問題を修正します。
    - 設定ファイルの検証・修復
    - キャッシュのクリア
    - MCP設定の検証
    - ログの確認
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Claude Desktop 起動エラー修正ツール" -ForegroundColor Cyan
Write-Host " (PowerShell版)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: プロセス終了 ---
Write-Host "[Step 1] Claude Desktopプロセスを終了しています..." -ForegroundColor Yellow
Get-Process -Name "Claude" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Write-Host "  完了" -ForegroundColor Green
Write-Host ""

# --- Step 2: 設定ファイルの検証 ---
Write-Host "[Step 2] 設定ファイルを検証しています..." -ForegroundColor Yellow

$configDir = Join-Path $env:APPDATA "Claude"
$configFile = Join-Path $configDir "claude_desktop_config.json"

Write-Host "  設定ファイル: $configFile"

if (-not (Test-Path $configFile)) {
    Write-Host "  設定ファイルが見つかりません。新規作成します..." -ForegroundColor Red
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    "{}" | Out-File -FilePath $configFile -Encoding UTF8
    Write-Host "  空の設定ファイルを作成しました。" -ForegroundColor Green
} else {
    # バックアップ作成
    $backupFile = "$configFile.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $configFile $backupFile
    Write-Host "  バックアップ: $backupFile" -ForegroundColor Green

    # JSON検証
    try {
        $configContent = Get-Content $configFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($configContent)) {
            throw "Empty file"
        }
        $config = $configContent | ConvertFrom-Json
        Write-Host "  設定ファイルのJSON形式: OK" -ForegroundColor Green

        # MCP設定の検証
        if ($config.mcpServers) {
            Write-Host "  MCP サーバー設定を検証中..." -ForegroundColor Yellow
            $mcpServers = $config.mcpServers
            $hasIssue = $false

            foreach ($prop in $mcpServers.PSObject.Properties) {
                $serverName = $prop.Name
                $serverConfig = $prop.Value

                # コマンドの存在確認
                if ($serverConfig.command) {
                    $cmd = $serverConfig.command
                    $cmdExists = Get-Command $cmd -ErrorAction SilentlyContinue
                    if (-not $cmdExists) {
                        # npx, node, pythonなどのパスも確認
                        $fullPath = $null
                        foreach ($p in @("$env:ProgramFiles\nodejs\$cmd.cmd", "$env:LOCALAPPDATA\Programs\Python\*\$cmd.exe", "$env:USERPROFILE\.nvm\*\$cmd.exe")) {
                            $resolved = Resolve-Path $p -ErrorAction SilentlyContinue
                            if ($resolved) { $fullPath = $resolved; break }
                        }
                        if (-not $fullPath) {
                            Write-Host "  [警告] MCPサーバー '$serverName' のコマンド '$cmd' が見つかりません" -ForegroundColor Red
                            $hasIssue = $true
                        }
                    } else {
                        Write-Host "  MCPサーバー '$serverName': OK ($cmd)" -ForegroundColor Green
                    }
                }
            }

            if ($hasIssue) {
                Write-Host ""
                Write-Host "  MCP設定に問題があります。問題のあるMCPサーバーを無効化しますか？" -ForegroundColor Red
                $response = Read-Host "  (y/N)"
                if ($response -eq 'y' -or $response -eq 'Y') {
                    # MCPサーバー設定を一時的に空にする
                    $config.mcpServers = [PSCustomObject]@{}
                    $config | ConvertTo-Json -Depth 10 | Out-File -FilePath $configFile -Encoding UTF8
                    Write-Host "  MCP設定を無効化しました。元の設定はバックアップから復元できます。" -ForegroundColor Green
                }
            }
        }
    } catch {
        Write-Host "  [問題検出] 設定ファイルが破損しています: $_" -ForegroundColor Red
        Write-Host "  設定ファイルをリセットします..." -ForegroundColor Yellow
        "{}" | Out-File -FilePath $configFile -Encoding UTF8
        Write-Host "  リセット完了" -ForegroundColor Green
    }
}
Write-Host ""

# --- Step 3: キャッシュクリア ---
Write-Host "[Step 3] キャッシュをクリアしています..." -ForegroundColor Yellow

$cacheDirs = @(
    (Join-Path $configDir "Cache"),
    (Join-Path $configDir "Code Cache"),
    (Join-Path $configDir "GPUCache"),
    (Join-Path $configDir "DawnCache"),
    (Join-Path $configDir "DawnWebGPUCache"),
    (Join-Path $configDir "blob_storage"),
    (Join-Path $configDir "Session Storage"),
    (Join-Path $configDir "Local Storage")
)

foreach ($dir in $cacheDirs) {
    if (Test-Path $dir) {
        Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  削除: $dir" -ForegroundColor Gray
    }
}
Write-Host "  キャッシュクリア完了" -ForegroundColor Green
Write-Host ""

# --- Step 4: ログ確認 ---
Write-Host "[Step 4] エラーログを確認しています..." -ForegroundColor Yellow

$logDir = Join-Path $configDir "logs"
if (Test-Path $logDir) {
    $latestLog = Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending |
                 Select-Object -First 1

    if ($latestLog) {
        Write-Host "  最新ログ: $($latestLog.FullName)" -ForegroundColor Gray
        Write-Host "  --- 最後の20行 ---" -ForegroundColor Gray
        Get-Content $latestLog.FullName -Tail 20 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        Write-Host "  ---" -ForegroundColor Gray
    }
} else {
    Write-Host "  ログディレクトリが見つかりません" -ForegroundColor Gray
}
Write-Host ""

# --- Step 5: 修正サマリー ---
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " 修正完了！" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "次のステップ:" -ForegroundColor White
Write-Host "  1. Claude Desktopを再起動してください"
Write-Host "  2. まだエラーが出る場合:" -ForegroundColor Yellow
Write-Host "     a. GPUを無効化して起動:"
Write-Host '        & "${env:LOCALAPPDATA}\Programs\claude\Claude.exe" --disable-gpu' -ForegroundColor Gray
Write-Host "     b. アプリをアンインストール→再インストール"
Write-Host "        (設定ファイルは保持されます)"
Write-Host "     c. 完全リセット: 設定フォルダを削除して再インストール"
Write-Host "        フォルダ: $configDir" -ForegroundColor Gray
Write-Host ""
Write-Host "バックアップファイル:" -ForegroundColor White
Write-Host "  $configFile.backup.*" -ForegroundColor Gray
Write-Host ""
Read-Host "Enterキーで終了"
