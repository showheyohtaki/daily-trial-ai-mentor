# デイトラちゃん — AIメンター for macOS

画面を見ながら、キャラクターボイスで教えてくれるAIメンター。

macOSメニューバーに常駐して、Control+Optionキーを長押しするだけで質問できます。プログラミング、デザイン、ライティング、語学——ジャンルを問わず、今見ている画面の内容を理解して答えてくれます。

### こんな使い方ができます

- エラーが出た画面を見せて「これどういう意味？」と聞く
- コードを開いたまま「この関数の処理を説明して」と話しかける
- デザインツールの操作中に「この余白どう調整すればいい？」と質問する
- ドキュメントを読みながら「要約して」とお願いする

## 主な機能

- **画面解析** — 画面を見て状況を理解。エラーもコードもデザインも把握します
- **音声対話** — 話しかけるだけで質問。キャラクターボイスで回答
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
