# Claude Desktop 起動エラー修正ツール

Windows上でClaude Desktopが起動時にエラーを表示する問題を修正するツールです。

## 主な修正内容

1. **設定ファイル（claude_desktop_config.json）の検証・修復** - 破損したJSONを検出しリセット
2. **MCPサーバー設定の検証** - 存在しないコマンドを参照するMCP設定を検出
3. **キャッシュのクリア** - 破損したキャッシュを削除
4. **ログの確認** - エラーの原因特定に役立つログを表示

## 使い方

### PowerShell版（推奨）

PowerShellを**管理者として実行**し、以下を入力:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\fix-claude-desktop.ps1
```

### バッチファイル版

`fix-claude-desktop.bat` をダブルクリックして実行してください。

## よくある原因

| 原因 | 症状 | 解決策 |
|------|------|--------|
| 設定ファイルの破損 | 起動直後にエラーダイアログ | スクリプトが自動修復 |
| MCP設定の問題 | 起動中にハング or エラー | MCP設定を無効化して確認 |
| GPUドライバの問題 | 白画面 or クラッシュ | `--disable-gpu` オプションで起動 |
| キャッシュの破損 | 予期しないエラー | キャッシュクリアで解決 |

## 手動での修正方法

設定ファイルの場所: `%APPDATA%\Claude\claude_desktop_config.json`

1. Claude Desktopを完全に終了（タスクマネージャーで確認）
2. 設定ファイルをテキストエディタで開く
3. 内容を `{}` に置き換えて保存
4. Claude Desktopを再起動
