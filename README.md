# Claude Desktop 起動エラー修正ツール

Windows上でClaude Desktop起動時に「**Claude Desktop failed to Launch**」エラーが表示される問題を修正するツールです。

MSIX版（新インストーラー）とSquirrel版（旧インストーラー）の両方に対応しています。

## 使い方

### PowerShell版（推奨）

PowerShellを**管理者として実行**し、以下を入力:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\fix-claude-desktop.ps1
```

### バッチファイル版

`fix-claude-desktop.bat` を右クリック → **管理者として実行** してください。

## 修正内容

| ステップ | 内容 |
|----------|------|
| 1 | Claude関連プロセスの完全終了 |
| 2 | インストール形式の検出 (MSIX / Squirrel / スタンドアロン) |
| 3 | インストールログの分析と原因特定 (Squirrelログ / MSIXデプロイログ / イベントログ / クラッシュダンプ) |
| 4 | CoworkVMService競合の検出と除去 |
| 5 | 旧MSIXパッケージの競合クリーンアップ (PowerShell版のみ) |
| 6 | 旧Squirrelインストールのクリーンアップ |
| 7 | Visual C++ / WebView2 ランタイムの確認 |
| 8 | CoreMessaging.dll の存在・整合性チェック |
| 9 | Windows バージョン互換性チェック / .NET Framework確認 |
| 10 | ユーザーデータの完全リセット (キャッシュ・一時ファイル削除) |
| 11 | 設定ファイル (claude_desktop_config.json) の検証・修復 / MCP設定の検証 |
| 12 | 起動テスト (MSIX版: shell:AppsFolder経由 / 旧版: --disable-gpu) |

## よくある原因

| 原因 | 症状 | 解決策 |
|------|------|--------|
| CoworkVMService残留 | インストール成功するが起動しない。Claude MSIX内の `cowork-svc.exe` の残留サービスで、`sc.exe delete` では削除不可 | スクリプトがレジストリから直接削除 |
| 旧MSIXパッケージ残留 | HRESULT 0x80073CFA エラー | スクリプトが旧パッケージを削除 |
| 旧Squirrelインストール残留 | MSIX版とSquirrel版が競合 | スクリプトが旧版をアンインストール |
| ユーザーデータの破損 | 起動直後に "failed to Launch" | スクリプトが自動リセット |
| 設定ファイルの破損 | 起動直後にエラーダイアログ | スクリプトが自動修復 |
| MCP設定の問題 | 起動中にハング or エラー | MCP設定を無効化して確認 |
| CoreMessaging.dll 破損/欠落 | 起動直後にクラッシュ or エラー | `DISM /Online /Cleanup-Image /RestoreHealth` で修復 |
| CoreMessaging.dll 互換性問題 | MSIX版で毎回クラッシュ。イベントログに `Faulting module: CoreMessaging.dll` | `sfc /scannow` + `DISM /Online /Cleanup-Image /RestoreHealth` で修復、Windows Update適用、Windows App SDK更新 |
| CoreMessaging.dll バージョン不整合 | DLLビルド番号とOSビルド番号が異なる (例: DLL=19041, OS=19045) | `sfc /scannow` + `DISM /Online /Cleanup-Image /RestoreHealth` + Windows Update |
| Windows 10 サービス終了バージョン | CoreMessaging.dllクラッシュで起動直後にエラー。ビルド19041(2004)等 | Windows 10 22H2に更新またはWindows 11にアップグレード |
| Windows バージョンが古い | インストール/起動失敗 | Windows 10 1809 (Build 17763) 以降に更新 |
| GPUドライバの問題 | 白画面 or クラッシュ | `--disable-gpu` オプションで起動 |
| Visual C++ 未インストール | 起動直後にクラッシュ | VC++ Redistributableをインストール |
| インストール破損 | 各種エラー | 再インストール |
| 原因不明の起動失敗 | エラーダイアログのみ | スクリプトがインストールログ・イベントログ・クラッシュダンプを自動分析して原因特定 |

## スクリプト実行後もエラーが続く場合

1. **再インストール**: https://claude.ai/download からダウンロードして再インストール
2. **MSIX版の場合 - 強制再インストール**:
   ```powershell
   Get-AppxPackage 'Claude' | Remove-AppxPackage
   ```
   その後、https://claude.ai/download から再インストール
3. **CoworkVMServiceの手動削除** (管理者権限のPowerShellで):
   ```powershell
   # sc.exe delete はMSIXパッケージ型サービスには使えないため、レジストリから直接削除
   sc.exe stop CoworkVMService
   Remove-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CoworkVMService' -Recurse -Force
   ```
4. **完全リセット**: `%APPDATA%\Claude` フォルダを削除してから再インストール
5. **Visual C++ Redistributable**: https://aka.ms/vs/17/release/vc_redist.x64.exe をインストール
6. **Windows Update**: 最新の状態に更新

## 手動での修正方法

1. タスクマネージャーでClaude関連プロセスを全て終了
2. 管理者権限のPowerShellで `sc.exe query CoworkVMService` を実行し、存在する場合はレジストリから削除: `Remove-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CoworkVMService' -Recurse -Force`
3. MSIX版の場合: `Get-AppxPackage 'Claude' | Remove-AppxPackage` でアンインストール後、再インストール
4. `%APPDATA%\Claude` フォルダ内のファイルを削除（claude_desktop_config.jsonは残す）
5. `claude_desktop_config.json` の内容を `{}` に置き換えて保存
6. Claude Desktopを再起動
