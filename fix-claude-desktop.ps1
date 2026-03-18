#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Desktop 起動エラー修正スクリプト (PowerShell版)
.DESCRIPTION
    "Claude Desktop failed to Launch" エラーを修正します。
    - プロセス完全終了
    - MSIX/Squirrel両インストール形式の検出と整合性チェック
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
Write-Host "[Step 1/12] Claude関連プロセスを完全終了..." -ForegroundColor Yellow

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
Write-Host "[Step 2/12] インストール形式を検出..." -ForegroundColor Yellow

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
# Step 3: CoworkVMService 競合の検出と除去
# ============================================================
Write-Host "[Step 3/12] CoworkVMService 競合を確認..." -ForegroundColor Yellow

# CoworkVMService はClaude MSIX パッケージ内の cowork-svc.exe が登録するサービス。
# 再インストール時に旧サービスが残留すると、新パッケージのインストール/起動が失敗する。
# MSIX パッケージ型サービス (type WIN32_PACKAGED_PROCESS) のため sc.exe delete では
# 削除できず、レジストリからの直接削除が必要。

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

    Write-Host "  このサービスはClaude (cowork-svc.exe) の残留サービスです。" -ForegroundColor Yellow
    Write-Host "  再インストール時に競合し、起動失敗の原因になります。" -ForegroundColor Yellow
    $issuesFound += "CoworkVMService 残留 (Claude cowork-svc.exe)"

    if ($isAdmin) {
        # まずサービスの停止を試行
        if ($coworkService -and $coworkService.Status -eq "Running") {
            try {
                Stop-Service -Name "CoworkVMService" -Force -ErrorAction Stop
                Write-Host "  サービスを停止しました" -ForegroundColor Green
            } catch {
                # sc.exe でも試行
                & sc.exe stop "CoworkVMService" 2>&1 | Out-Null
                Write-Host "  サービス停止を試行しました" -ForegroundColor Yellow
            }
        }

        # MSIX パッケージ型サービスは sc.exe delete では削除できないため
        # レジストリから直接削除する
        if ($coworkRegExists) {
            try {
                Remove-Item -Path $svcRegPath -Recurse -Force -ErrorAction Stop
                Write-Host "  レジストリからサービスを削除しました" -ForegroundColor Green
            } catch {
                Write-Host "  レジストリ削除に失敗: $_" -ForegroundColor Red
                Write-Host "  手動で削除してください:" -ForegroundColor Yellow
                Write-Host "    Remove-Item -Path '$svcRegPath' -Recurse -Force" -ForegroundColor Gray
            }
        }
    } else {
        Write-Host "  [要管理者権限] サービスの除去には管理者権限が必要です。" -ForegroundColor Yellow
        Write-Host "  管理者権限でPowerShellを起動し、以下を実行してください:" -ForegroundColor Yellow
        Write-Host "    Remove-Item -Path '$svcRegPath' -Recurse -Force" -ForegroundColor Gray
    }
} else {
    Write-Host "  CoworkVMService なし - OK" -ForegroundColor Green
}
Write-Host ""

# ============================================================
# Step 4: 旧MSIXパッケージの競合クリーンアップ
# ============================================================
Write-Host "[Step 4/12] 旧MSIXパッケージの競合を確認..." -ForegroundColor Yellow

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
# Step 5: 旧Squirrelインストールのクリーンアップ
# ============================================================
Write-Host "[Step 5/12] 旧Squirrelインストールのクリーンアップ..." -ForegroundColor Yellow

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
# Step 6: Visual C++ ランタイムの確認
# ============================================================
Write-Host "[Step 6/12] Visual C++ ランタイムを確認..." -ForegroundColor Yellow

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
# Step 7: WebView2 ランタイムの確認
# ============================================================
Write-Host "[Step 7/12] WebView2 ランタイムを確認..." -ForegroundColor Yellow

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
# Step 8: CoreMessaging.dll の確認
# ============================================================
Write-Host "[Step 8/12] CoreMessaging.dll を確認..." -ForegroundColor Yellow

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

# CoreMessaging.dll での過去のクラッシュを検出 (例外コード 0xc0000602)
try {
    $coreMsgCrashes = Get-WinEvent -LogName Application -MaxEvents 100 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Message -match "Claude" -and
            $_.Message -match "CoreMessaging\.dll" -and
            $_.Message -match "0xc0000602"
        } | Select-Object -First 1

    if ($coreMsgCrashes) {
        $coreMsgCrashDetected = $true
        Write-Host "  [問題] CoreMessaging.dll クラッシュ (0xc0000602) を検出" -ForegroundColor Red
        Write-Host "  STATUS_FAIL_FAST_EXCEPTION: MSIX パッケージと CoreMessaging.dll の互換性問題" -ForegroundColor Yellow
        $issuesFound += "CoreMessaging.dll クラッシュ (0xc0000602)"

        # 対処1: Windows App Runtime の確認
        Write-Host "" -ForegroundColor Gray
        Write-Host "  --- CoreMessaging.dll 互換性問題の自動修復 ---" -ForegroundColor Cyan

        # フレームワークパッケージの再登録
        Write-Host "  フレームワークパッケージを再登録しています..." -ForegroundColor Gray
        Get-AppxPackage -AllUsers "*Framework*" -ErrorAction SilentlyContinue | ForEach-Object {
            $manifestPath = Join-Path $_.InstallLocation "AppxManifest.xml"
            if (Test-Path $manifestPath) {
                Add-AppxPackage -Register $manifestPath -DisableDevelopmentMode -ErrorAction SilentlyContinue
            }
        }
        Write-Host "  フレームワーク再登録完了" -ForegroundColor Green

        # Windows App Runtime の最新バージョン確認
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
        Write-Host "  1. Windows Updateで最新の状態に更新" -ForegroundColor White
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
# Step 9: Windows バージョン互換性チェック
# ============================================================
Write-Host "[Step 9/12] Windows バージョン互換性を確認..." -ForegroundColor Yellow

$osVersion = [System.Environment]::OSVersion.Version
$osBuild = $osVersion.Build
Write-Host "  Windows バージョン: $($osVersion.Major).$($osVersion.Minor) ビルド $osBuild" -ForegroundColor Gray

# Windows 10 1809 (Build 17763) 以降が必要 (Electron/WebView2の要件)
if ($osVersion.Major -lt 10) {
    Write-Host "  [問題] Windows 10 以降が必要です" -ForegroundColor Red
    $issuesFound += "Windows バージョンが古い (Windows 10未満)"
} elseif ($osVersion.Major -eq 10 -and $osBuild -lt 17763) {
    Write-Host "  [問題] Windows 10 バージョン 1809 (ビルド 17763) 以降が必要です" -ForegroundColor Red
    Write-Host "  現在のビルド: $osBuild" -ForegroundColor Yellow
    Write-Host "  Windows Updateで最新バージョンに更新してください" -ForegroundColor Yellow
    $issuesFound += "Windows ビルドが古い ($osBuild < 17763)"
} else {
    Write-Host "  Windows バージョン: 互換性OK" -ForegroundColor Green
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
# Step 10: ユーザーデータの完全リセット
# ============================================================
Write-Host "[Step 10/12] ユーザーデータをリセット..." -ForegroundColor Yellow

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
# Step 11: 設定ファイルの検証・修復
# ============================================================
Write-Host "[Step 11/12] 設定ファイルを検証・修復..." -ForegroundColor Yellow

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
# Step 12: 修復後の起動テスト
# ============================================================
Write-Host "[Step 12/12] 修復後の起動テスト..." -ForegroundColor Yellow

# Windowsイベントログの確認
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
    Write-Host "  3. CoworkVMServiceが存在する場合は管理者権限で削除:" -ForegroundColor White
    Write-Host "     sc.exe delete CoworkVMService" -ForegroundColor Gray
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
