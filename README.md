# Claude Desktop 起動エラー修正ツール

Windows上でClaude Desktop起動時に「**Claude Desktop failed to Launch**」エラーが表示される問題を修正するツールです。

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
| 2 | インストール状態の確認 (app.asarの整合性チェック) |
| 3 | Visual C++ ランタイムの確認 |
| 4 | WebView2 ランタイムの確認 (PowerShell版のみ) |
| 5 | ユーザーデータの完全リセット (キャッシュ・一時ファイル削除) |
| 6 | 設定ファイル (claude_desktop_config.json) の検証・修復 |
| 7 | MCP設定の検証 (PowerShell版のみ) |
| 8 | `--disable-gpu` オプションでの起動テスト |

## よくある原因

| 原因 | 症状 | 解決策 |
|------|------|--------|
| ユーザーデータの破損 | 起動直後に "failed to Launch" | スクリプトが自動リセット |
| 設定ファイルの破損 | 起動直後にエラーダイアログ | スクリプトが自動修復 |
| MCP設定の問題 | 起動中にハング or エラー | MCP設定を無効化して確認 |
| GPUドライバの問題 | 白画面 or クラッシュ | `--disable-gpu` オプションで起動 |
| Visual C++ 未インストール | 起動直後にクラッシュ | VC++ Redistributableをインストール |
| インストール破損 | 各種エラー | 再インストール |

## スクリプト実行後もエラーが続く場合

1. **再インストール**: https://claude.ai/download からダウンロードして再インストール
2. **完全リセット**: `%APPDATA%\Claude` フォルダを削除してから再インストール
3. **Visual C++ Redistributable**: https://aka.ms/vs/17/release/vc_redist.x64.exe をインストール
4. **Windows Update**: 最新の状態に更新

## 手動での修正方法

1. タスクマネージャーでClaude関連プロセスを全て終了
2. `%APPDATA%\Claude` フォルダ内のファイルを削除（claude_desktop_config.jsonは残す）
3. `claude_desktop_config.json` の内容を `{}` に置き換えて保存
4. Claude Desktopを再起動
