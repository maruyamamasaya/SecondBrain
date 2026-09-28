# SecondBrain

SecondBrainは、Thought・AI・Knowledge・Apps / Toolsをひとつの場所から扱うための個人用AIワークスペースです。

開発は、X（旧Twitter）のTimelineのように140文字以内の短いテキストを記録するiOSアプリ`AiTextApp_iOS`から始まりました。現在はThoughtを中核として、AI Personaとの会話、振り返り、Knowledge管理、External Brain、個人用ツールへの入口を統合する方向へ発展させています。

リポジトリ名とXcode projectは`AiTextApp_iOS`、現在のアプリ表示名は`AiTextApp`、Core package名は`ThoughtCore`です。`SecondBrain`はプロダクト全体の名称として扱います。

## Concept

SecondBrainの中心はThoughtです。思いつきや考えを気軽に残し、AIとの会話、振り返り、Knowledge化、各種ツールの利用へつなげます。

```text
SecondBrain
├─ Thought
├─ AI
├─ Knowledge
├─ Insights
└─ Apps / Tools
   ├─ Native Features
   ├─ GitHub Pages
   ├─ Web Apps
   ├─ Local Tools
   └─ External Services
```

SecondBrain自体ですべてを再実装するのではなく、Native機能と外部のアプリ／サービスを共通の入口から扱える個人用インターフェースを目指します。Apps / Toolsの統合Hubは構想・設計準備段階で、現行アプリにはまだ実装されていません。

## Thought

HumanとAI Personaの短い投稿を同じTimelineで扱います。Mention、Reply、ContinuationからConversationを構成し、Thoughtを次の処理へつなげられます。

- AI Personaとの会話・投稿依頼
- Daily Summary、Weekly Review、Journal
- Knowledge Draft、Review、Promote
- Tag、Search、Insights / Analytics
- Backup、Restore、Export

## AI

複数のAIを独立したPersonaとして扱い、Personaごとに役割、指示、生成Provider、External Brainを設定します。現在はGeminiとOpenAIの生成経路を実装しています。Claudeは設定画面上で未対応と明示しています。

GeminiはFirebase AI LogicとApp Checkを利用します。OpenAIは個人所有端末へXcodeから導入する期間に限り、Keychainへ保存したAPI keyでResponses APIへ直接接続する暫定構成です。配布前にはバックエンドのSecret管理へ移行する必要があります。

## Knowledge / External Brain

ThoughtやAIとの会話からKnowledge Draftを生成し、人間によるReviewとApproveを経て正式KnowledgeへPromoteします。正式KnowledgeはGitHubを正本とし、ローカルへ同期・索引化した内容をAI Personaが必要に応じて参照します。

```text
Thought
  ↓
AI / Review
  ↓
Knowledge Draft
  ↓
Human Review
  ↓
Knowledge（GitHub）
  ↓
External Brain
  ↓
AI Persona
```

## Current Status

現行のiOSアプリには、次の主要機能があります。

- Thought Timeline、Search、Tag、soft delete
- Mention、Reply、Continuation、Conversation
- AI Persona、Gemini / OpenAI Provider、AI Reply / Persona Post
- Daily Summary、Weekly Review、Journal、Local / AI Usage Analytics
- External Brain、Knowledge Draft、Review / Promote、Knowledge Quality
- GitHub Repository連携
- Markdown / JSON Export、内部／外部Backup、Restore
- iOS accessibility、Theme

SQLite schemaはv20です。週間振り返りと日記表示修正を含む最新コードは、Swift 6.3で判明したcompile blockerのため検証完了前です。正確な実装・検証状況は[`CURRENT.md`](CURRENT.md)、Macでの残作業は[`MAC_VALIDATION.md`](MAC_VALIDATION.md)を参照してください。

## Apps / Tools

将来は、SecondBrain内のNative機能、GitHub Pages、独立Webアプリ、ローカルネットワーク上のWebアプリ、外部サービスを共通の`App`として扱います。初期設計の前提、候補scope、未決定事項は[`NEXT_FEATURES.md`](NEXT_FEATURES.md)にまとめています。

## Development

`AiTextApp.xcodeproj`をXcode 26.2以降で開き、`AiTextApp` schemeを実行します。対象はiOS 16以降です。UI非依存のCore testは`swift test`、アプリのbuildとXCUITestはXcode環境で実行します。

FirebaseとOpenAIの設定、秘密情報の扱い、Backup / Restoreは[`OPERATIONS.md`](OPERATIONS.md)を確認してください。

## Documents

| 目的 | ドキュメント |
| --- | --- |
| 現在地・既知の問題・直近の優先順位 | [`CURRENT.md`](CURRENT.md) |
| 次期機能の候補と設計準備 | [`NEXT_FEATURES.md`](NEXT_FEATURES.md) |
| 現在のアーキテクチャ | [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| 機能からコードを探す | [`CODEMAP.md`](CODEMAP.md) |
| 検証方法 | [`TESTING.md`](TESTING.md) |
| 開発・外部サービス・データ保全 | [`OPERATIONS.md`](OPERATIONS.md) |
| AIエージェント作業規約 | [`AGENTS.md`](AGENTS.md) |
| 重要な設計判断 | [`decisions/`](decisions/) |
| 作業履歴 | [`sessions/`](sessions/) |
