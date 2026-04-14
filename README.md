# デイトラちゃん — AIメンター for macOS

画面を見ながら、ずんだもんの声で教えてくれるAIメンター。デイトラ受講生向け。

macOSメニューバーに常駐して、Control+Optionキーを長押しするだけで質問できます。

## 主な機能

- **画面解析** — 画面を見て状況を理解。エラーもコードも把握します
- **音声対話** — 話しかけるだけで質問。ずんだもんの声で回答
- **ポインティング** — 画面上の要素を直接指し示して説明
- **会話ログ** — 対話履歴をテキストで確認
- **速度切り替え** — 1.0x / 1.1x / 1.2x

## ダウンロード

[DaytoraAIMentor.dmg](https://github.com/showheyohtaki/daily-trial-ai-mentor/releases/download/v1.0/DaytoraAIMentor.dmg)（約150MB）

## セットアップ

1. DMGを開いてアプリをApplicationsにドラッグ
2. 初回起動時「開発元が未確認」と出たら、システム設定 > プライバシーとセキュリティ > 「このまま開く」
3. [Anthropic Console](https://console.anthropic.com)でAPIキーを取得し、アプリに入力
4. Control+Optionを長押しして話しかける

## 動作環境

- macOS 14.2（Sonoma）以上
- Anthropic APIキーが必要（従量課金）
- Apple Silicon / Intel Mac 対応

## 必要な権限

- **マイク** — 音声入力
- **アクセシビリティ** — グローバルキーボードショートカット
- **画面収録** — スクリーンショット撮影

## 開発

```bash
# VOICEVOXエンジンをセットアップ（要: VOICEVOX.appインストール済み）
./scripts/setup-voicevox.sh

# Xcodeで開く
open leanring-buddy.xcodeproj

# Debug版ビルド → Applicationsにコピー
./scripts/dev.sh

# Release版DMG作成
./scripts/release.sh
```

## クレジット

- VOICEVOX:ずんだもん
- Based on [Clicky](https://github.com/farzaa/clicky) by Farza — MIT License
