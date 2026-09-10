# 0007: ローカルAIアカウントをTimeline参加者として扱う

- Status: Accepted
- Date: 2026-09-11

## Context

現在の`Persona`は内部UUID、表示名、種別、アイコンを持ち、Thoughtの投稿者として人間とAIを共通に扱う。AI Personaは役割・指示と明示的な投稿依頼も持つが、SNSのような公開用アカウントID、ニックネームと自己紹介、AIサービス設定の独立管理、メンションに対するContinuation返信はまだない。

端末所有者1人と複数のAIが同じTimelineへ参加する体験を作りたい。AIアカウントはiPhone上で自由に作成し、ユーザーが決めた一意の`@account_id`と自由なニックネームを持つ。外部AIサービスの識別子や認証設定は、このSNS上のアカウントIDとは別物である。

## Decision

### 共通原則

- アプリを、端末所有者と複数のローカルAIアカウントが参加するプライベートTimelineとして扱う。
- 既存`Persona.id`のUUIDを不変の内部参照IDとして維持する。Thought、Continuation、生成来歴、メンションは引き続きUUIDを参照する。
- `accountID`は人間が認識・入力する公開用ID、`nickname`は自由な表示名とする。両者を外部AIサービスのアカウント、provider、model、credentialから分離する。
- 端末所有者は固定UUIDを持つ唯一のhumanとし、追加作成できるアカウントはすべてAIとする。
- AI通信はユーザーの明示確認後だけ行う。Phase A〜Cでは自発投稿、バックグラウンド巡回、AI同士の自動会話を行わない。
- AI生成Thoughtも通常のThoughtとして同じTimeline、検索、タグ、History、Review、backupの対象にする。生成来歴はThought本文と分離して保持する。

### 識別子とプロフィール

`Persona`は概念上、次を持つ。

```text
id             UUID       内部主キー、変更不可、通常は非表示
accountID      String     @を除いた正規化済み公開ID、端末内で一意
nickname       String     自由な表示名、重複可
biography      String?    自己紹介
kind           human|ai
icon           JPEG BLOB
createdAt / updatedAt / deletedAt
```

`accountID`のv1規則は以下とする。

- 入力時の先頭`@`は許容して除去する。
- Unicode互換正規化後にPOSIX localeで小文字化する。
- 保存可能文字はASCII小文字、数字、underscoreとし、先頭は英小文字とする。
- 長さは3〜24文字とする。
- 正規化済み値をSQLiteのUNIQUE制約で一意にする。
- `me`、`self`、`system`、`admin`、`support`、`ai`を予約語とする。予約語判定はCoreとUIで共有する。
- ID変更は許可するが内部UUIDは変えない。過去Thoughtは現在のプロフィールを表示するため、新しいIDへ表示が切り替わる。

`nickname`はtrim後1〜40文字、Unicodeと絵文字を許容し、重複を許す。`biography`は任意でtrim後160文字以内とする。Timelineでは`nickname`、`@accountID`、AI種別を併記し、VoiceOverでもAIであることを明示する。

### Phase A: AIアカウントプロフィール

schema v9で`personas`へ`account_id`、`biography`を追加する。既存`display_name` columnは互換性を保ってnicknameの正本として使い、コード上の命名を段階的に`nickname`へ寄せる。大規模なtable再構築は行わない。

Migrationは次を満たす。

- 固定humanには衝突しない既定IDを付与する。第一候補を`owner`とし、衝突時は決定的suffixを付ける。
- 既存AIには表示名から規則に合うslugを生成し、不足時は`ai_<UUID先頭8文字>`、衝突時は決定的suffixを使う。
- 全行を埋めてから一意indexを作る。失敗時はtransaction全体をrollbackする。
- 既存UUID、Thought投稿者、メンション、生成来歴を変更しない。

設定の「プロフィール／AI Persona」は「アカウント」へ整理する。自分とAIアカウント一覧を分け、AIの作成・編集画面でアイコン、ニックネーム、アカウントID、自己紹介、役割、指示を編集する。作成時はプロフィールとAI設定を同一transactionで保存する。AIの無効化は既存soft deleteを使い、過去投稿は残す。無効アカウントは新規メンション・生成対象から除外する。

Timelineの投稿者行は`nickname @accountID AI`を表示する。投稿者を選択するとプロフィールと、そのUUIDがauthorであるactive Thoughtの新しい順一覧を開く。プロフィール一覧取得は本文検索とは分離したRepository queryにする。

Phase A完了条件:

- v8からv9へデータを失わずmigrationできる。
- 自分と複数AIのID・ニックネーム・自己紹介を編集できる。
- ID正規化、予約語、重複を保存境界でも拒否する。
- Timeline、Detail、検索結果で同じアカウント表示になる。
- AIプロフィールから当該AIの投稿一覧を開ける。

### Phase B: AIサービス設定の分離

AIアカウントの人格と外部サービス接続を別モデルにする。

```text
AIConnection
  id
  label
  provider
  model
  isEnabled
  createdAt / updatedAt

AIPersonaConfiguration
  personaID
  role
  instructions
  connectionID?
```

schema v10で`ai_connections`を追加し、`ai_persona_configurations.connection_id`から任意参照する。1接続を複数AIで共有でき、AIアカウントは接続未設定のまま保存できる。接続の削除は、参照中なら拒否するか先に関連解除を求め、暗黙のcascade deleteはしない。

provider/modelは接続設定の現在値、`ai_post_generations`のprovider/modelは生成時点の監査snapshotとして維持する。既存Firebase構成から既定接続をmigrationし、既存AIへ割り当てる。ただし`GoogleService-Info.plist`がない場合もアカウントと接続レコードの管理は可能にする。

credential、API key、App Check tokenをSQLite、Export、backup用manifest、ログへ保存しない。v1のFirebase AI Logicはアプリ同梱構成とApp Checkを使うため、設定画面ではcredential入力を提供せず、利用可否と接続確認結果だけを表示する。将来ユーザーcredentialを扱うproviderを追加する場合はKeychain境界を別途設計する。

設定内に「AIサービス」を設け、接続名、provider、model、有効状態、構成状態、明示的な接続テストを表示する。接続テストはThoughtを作成せず、保存済み人格も変更しない。生成時はactiveなAI、完全な人格設定、有効で利用可能な接続をすべて検証する。

Phase B完了条件:

- AIアカウントとprovider/modelを独立して編集できる。
- 複数AIが同じ接続を共有できる。
- 接続未設定・無効・Firebase未構成を区別して表示できる。
- 接続変更後も過去生成記録のprovider/modelが変化しない。
- 接続テストがTimelineとSQLite Thoughtを変更しない。

### Phase C: メンションからのContinuation返信

既存の単一メンションを返信依頼の入口として使う。Phase Cでも1 ThoughtにつきactiveなAIメンションは1件とし、本文中の`@文字列`を後から解析せず、Composerで選択したPersona UUIDを正本にする。

基本フロー:

```text
自分がAIを選択してThoughtを投稿
  -> Thoughtとmentionを同一transactionで保存
  -> 「このAIに返信を依頼」確認を表示
  -> 対象Thought、Continuation文脈、AI人格、接続、最終payloadをpreview
  -> ユーザーが確定
  -> AIへ1回だけ送信
  -> 140文字以内の応答をAI名義Thought + continues Relation + generationとして同一transaction保存
```

メンション付きThoughtの投稿成功とAI返信は別transactionにする。通信失敗によって人間の元Thoughtをrollbackしない。確認をキャンセルしてもmentionは残り、Thoughtのメニューから後で返信を依頼できる。

送信文脈は対象Thoughtを必須とし、そのThoughtが属するContinuation chainのactiveな先祖を、件数または文字数上限内で古い順に含める。Timeline全体、無関係なThought、削除済み本文は送らない。preview作成後、送信直前に対象Thought、Relation、Persona設定、接続設定を再取得し、変更があれば古いpreviewを送らず再確認を求める。

AI返信は対象Thoughtをtarget、新しいAI Thoughtをsourceとする`continues` Relationで保存する。新しいRepository境界はThought、author、Relation、generationを一つのtransactionで保存し、いずれかの失敗時は全てrollbackする。同じpreviewからの二重送信を防ぐidempotency IDを生成記録へ保存し、DBの一意制約で重複返信を拒否する。

返信失敗は未生成、通信中、再試行可能、構成エラー、対象変更、保存失敗を区別する。空応答、140文字超過、不正なAI投稿者、無効アカウントは保存しない。AIの返信に別AIへのメンションが含まれても自動連鎖を開始しない。

Phase C完了条件:

- メンション付き人間Thoughtを保存し、確認をキャンセルしても保持できる。
- previewで外部送信対象を確認できる。
- 確定後だけAI通信し、返信を正しいAI名義のContinuationとして保存できる。
- 通信失敗時に元Thoughtを失わず再試行できる。
- 鮮度確認、二重送信防止、transaction rollbackをテストできる。
- AI同士の自動応答やバックグラウンド通信が発生しない。

## Roadmap

1. Phase A1: Core validation、schema v9 migration、Repository。
2. Phase A2: アカウント一覧・作成編集・Timeline表示。
3. Phase A3: プロフィールとアカウント別Thought一覧、アクセシビリティ、実機確認。
4. Phase B1: `AIConnection`、schema v10、既存Firebase構成のmigration。
5. Phase B2: AIサービス設定UI、アカウントへの割当、接続テスト。
6. Phase C1: immutable返信previewと鮮度検証。
7. Phase C2: AI返信用atomic transactionとidempotency、UIフロー。
8. Phase C3: Unit／SQLite／XCUITest、Firebase Debug実通信、Release App Attest確認。

各Phaseはmigration、Core test、Simulator build、主要XCUITestを通してから次へ進む。Phase Bの実API確認ができなくても、MockでPhase CのCore/UIを開発できる境界を維持する。

## Reason

公開用IDをUUIDから分離すれば、ユーザーがIDを変更しても既存投稿と関連を壊さない。人格と接続を分離すれば、同じAIアカウントのモデル変更や、複数人格による接続共有が可能になる。返信を明示確認とContinuationへ限定すれば、現在の原文保全、送信前確認、原子的保存という設計を保ったままSNSらしい参加体験を追加できる。

## Alternatives

- `accountID`を主キーにする案は、ID変更が全関連へ波及するため採用しない。
- ニックネームを一意にする案は、SNS風の自由な表示名を妨げるため採用しない。
- Persona内へprovider/model/credentialを直接持たせる案は、人格と実行基盤を密結合にするため採用しない。
- メンション投稿とAI返信を一つのtransactionにする案は、外部通信失敗で人間のThoughtまで失うため採用しない。
- Phase Cから自動返信を有効にする案は、意図しない通信、費用、応答連鎖を生むため採用しない。

## Consequences

- schema v9〜v11の段階的migrationと既存データ互換テストが必要になる。
- 表示名中心だった既存UIを、nicknameと`@accountID`の二つを扱うUIへ更新する必要がある。
- AI接続を共有できる一方、接続無効化時の影響を参照中アカウントへ明示する必要がある。
- Phase Cでは生成結果だけでなくRelationとidempotencyを含む新しいatomic保存境界が必要になる。
- 自発活動、複数メンション、AI同士の自動会話、クラウド上のユーザーアカウントは後続Decisionで扱う。
