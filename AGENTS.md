# AI Agent Guide

このリポジトリでは、ソースコード・設定・テストを実装状態の正本とします。文書と矛盾した場合は実物を再調査し、「実装上の事実」「意図された仕様」「過去の判断」「不具合」を区別して文書を直してください。

## 言語方針

- ユーザー向けのアプリ内表示と開発ドキュメントは、プロンプトの言語にかかわらず日本語を基本とする。
- API、Swiftの型名、ファイル名、パス、GitHubの固有用語など、正確性や検索性のため必要な技術語は英語のままでよい。

## Project Context

- **Project Name:** プロダクト名は`SecondBrain`。リポジトリ／Xcode project名は`AiTextApp_iOS`、現在のアプリ表示名は`SecondBrain`、Core package名は`ThoughtCore`。
- **Purpose:** Thoughtを中核として、人間とAI Personaの会話、振り返り、Knowledge、External Brain、個人用Apps / Toolsへの入口を統合するiPhone向け個人用AIワークスペース。Thoughtは140文字以内の短文を基本とする。
- **Primary Stack:** Swift 5 language mode／Swift 6 package、SwiftUI、Combine、Foundation、SQLite、iOS 16以降、Xcode project + Swift Package。Firebase Apple SDKをapp targetで利用する。
- **External Services / APIs:** GeminiはFirebase AI Logic + App Check、OpenAIは個人所有端末限定のResponses API直接接続、External Brain／KnowledgeはGitHub APIを利用する。OpenAI API keyとGitHub tokenはKeychainへ保存する。現時点で利用者アカウント、独自バックエンド、クラウド同期は持たない。Claude生成経路は未実装。
- **Main Domains:** Thoughtの入力検証・Timeline・soft delete、Mention／Reply／Continuation／Conversation、AI Personaと生成、Daily Summary／Weekly Review／Journal、Tag／Search／Analytics、SQLite永続化・旧JSON migration・内部／外部backup・restore、Markdown／JSON Export、External Brain、Knowledge Draft／Review／Promote／Quality、iOS accessibility。
- **Expected Work:** 上記領域のiOS UI、ドメイン／repository、外部API境界、秘密情報管理、データ保全、テスト、ドキュメント、運用改善。Apps / Tools Hub、AI派生情報、同期、共有など、SecondBrainの目的に沿う新領域も追加調査のうえ対象になり得る。
- **Clearly Unrelated Examples:** 別製品固有のNext.js管理画面やWebゲーム、Android専用画面、別サービス固有のDB table／route、存在しない別プロジェクト名・固有class・固有directoryを前提にした変更。この例は新機能を制限するホワイトリストではない。

## Project Context Guard

ユーザー要求を受けたら、**ファイル変更、パッケージ追加、DB変更、破壊的コマンド、commit、pushなどの実装操作を始める前**に、要求と上記Project Contextの整合性を判定します。判定に必要な、Git root確認、文書・manifest・directory・コードの検索などのread-only調査は実施できます。

### MATCH

現在のプロジェクトと明確に関連する要求です。既存の作業手順に従って通常どおり進めます。

### UNCERTAIN

このプロジェクトで実現可能だが、新技術・新領域・大きな構成変更を含むなど、文脈だけでは判断しづらい要求です。自動的に拒否せず、関連文書、実装、manifest、履歴、テストを追加調査してから作業可否を判断します。正当な新機能であることを確認できればMATCHとして進めます。確認後も重要な前提が不足する場合は、変更前にユーザーへ確認します。

### MISMATCH

明らかに別プロジェクト向けであると高い確信を持てる要求です。別プロジェクト名、別製品固有機能、固有ファイル／class名、明確に異なるplatform、複数の矛盾したsignalを総合して判断します。`SQLite`、`React`、`API`、`Docker`、`Python`、`Swift`、`database`などの一般技術名や単一keywordだけではMISMATCHにせず、迷う場合はUNCERTAINとします。

MISMATCHの場合は直ちに作業を停止し、次を行いません。

- ファイル変更・新規ファイル作成
- パッケージ追加・DB変更
- destructive command
- commit・push

応答には、`Current Project`、Mismatchと判断した理由、prompt内の不一致要素、`No files were modified`を簡潔に記載します。

## Repository Boundaries

- 作業開始時に`git rev-parse --show-toplevel`で現在のGit rootを確認し、対象がこのリポジトリであることを確かめます。
- 原則としてGit root外のファイル、および隣接・別リポジトリを読み書き・変更しません。
- ユーザーが別リポジトリの操作を明示的に依頼した場合だけ、その対象と境界を確認してから例外として扱います。
- pathや作業対象に疑義がある場合は変更せず、追加調査またはユーザー確認を行います。

## 作業開始時

1. `CURRENT.md` を読む。
2. この `AGENTS.md` のルールを確認する。
3. 必要に応じて `ARCHITECTURE.md` を読む。
4. コードの場所は `CODEMAP.md` から探す。
5. 検証方法は `TESTING.md` を確認する。
6. 環境・起動・運用・配布の変更では `OPERATIONS.md` を確認する。
7. 設計判断が関係する場合は `decisions/` を確認する。

推奨導線は `CURRENT.md` → 必要な専門文書 → `CODEMAP.md` → コード検索 → 対象コードです。

## コード調査時

全ファイルを順に読む前に、`rg`、`git grep`、IDEのシンボル検索、language serverなど利用可能な検索を使います。関数名、型・クラス・Component名、Route/API path、DB table、環境変数、エラーメッセージ、feature名、test名、`TODO|FIXME` を手掛かりにしてください。

```bash
rg "FeatureName|TypeName"
rg "/api/example"
rg "DATABASE_URL|TODO|FIXME"
git grep "error message"
```

検索結果から **入口 → 主要処理 → データアクセス → 外部依存 → テスト** の順に、呼び出し元・呼び出し先を確認してから変更します。一般的な流れは、文書を読む → キーワード検索 → 関連コード特定 → 呼び出し関係確認 → 関連テスト特定 → 変更 → 検証です。

## 作業中

- 既存仕様を尊重し、コードだけから仕様を決めつけない。
- 不明点を推測で固定せず、必要なら「未確認」と記録する。
- 要求に関係する範囲だけを、小さく安全に変更する。
- 不要なリファクタリング、依存更新、機能追加を混ぜない。
- 実装前に関連テストを探し、変更の境界を把握する。
- 将来の担当者が理由を推測できない重要判断だけ `decisions/` に記録する。
- 認証情報、署名情報、トークン、個人情報を文書やコミットへ含めない。

## Xcodeのストレージ管理

iOS／macOSプロジェクトの検証では、Macのストレージ消費を最小限にします。

- 変更内容の確認にビルドだけで十分なら、`xcodebuild test`は実行しない。
- テストが必要な場合は、既存のSimulatorを1台だけ使用する。
- 並列テストを無効にし、`-parallel-testing-enabled NO`と`-maximum-parallel-testing-workers 1`を指定する。
- 同じテストを理由なく繰り返さない。
- 新しいSimulator、テスト端末、ランタイムを必要なく作成・ダウンロードしない。
- テスト開始前に`~/Library/Developer/XCTestDevices`の既存フォルダ一覧と容量を記録する。
- テスト完了後、そのタスクによって新規作成された`XCTestDevices`内のUUIDフォルダだけを削除する。以前から存在するデータは削除しない。
- Xcode、Simulator、またはテスト処理が実行中の場合は削除せず、状況を報告する。
- DerivedDataなど、ほかのXcodeデータを削除する場合は事前にユーザーへ確認する。
- 最後に、作成・削除したテスト端末の数と、`XCTestDevices`に残っている容量を報告する。

## 作業終了時

変更に応じて `TESTING.md` から lint、typecheck、unit/integration/E2E test、buildを選んで実行します。その後、次を必要な場合だけ更新します。

- 毎回: `sessions/` に簡潔な作業記録を残す。
- 状態変更: `CURRENT.md`
- 構成変更: `ARCHITECTURE.md`
- 主要コード配置変更: `CODEMAP.md`
- 検証方法変更: `TESTING.md`
- 起動・環境・配布方法変更: `OPERATIONS.md`

## 文書の役割

- `CURRENT.md`: 今どこまでできているか。
- `NEXT_FEATURES.md`: 次期機能の候補、未決定事項、設計開始条件。
- `ARCHITECTURE.md`: 現在システムがどう動いているか。
- `CODEMAP.md`: どの主要コードがどこにあるか。
- `TESTING.md`: どう検証するか。
- `OPERATIONS.md`: どう起動・運用・デプロイするか。
- `decisions/`: なぜ重要な設計を選んだか。
- `sessions/`: 過去に何を調査・変更したか。
- `README.md`: 人間向けの概要と入口。
