# AIアカウント Phase A〜C設計

## 依頼

端末内SNSとして、自分と複数AIアカウントが同じTimelineへ参加するPhase A〜Cを段階的に設計する。

## 調査

- 既存`Persona`は不変UUID、表示名、human／AI種別、アイコン、soft deleteを持つ。
- schema v8は投稿者、AI人格設定、生成来歴、単一AIメンションをThought本文から分離している。
- 現在のAI投稿は明示依頼とpreview後にAI名義で保存するが、メンションからContinuation返信する処理はない。

## 変更

- Decision 0007へ公開用`@accountID`、ニックネーム、自己紹介の規則を記録した。
- Phase Aをschema v9のアカウントプロフィール、Phase Bをschema v10のAI接続分離、Phase Cをメンション返信とschema v11相当の生成整合性強化として設計した。
- migration、transaction、送信文脈、鮮度確認、idempotency、エラー境界、各Phaseの完了条件を定義した。

## 検証

- 文書変更のみ。コード、DB、テストは変更・実行していない。
- `git diff --check`で文書差分を確認する。

## 実装結果

- Phase A: 公開用ID、ニックネーム、自己紹介、プロフィール／投稿一覧、schema v9 migrationを実装。
- Phase B: AI接続モデル、既定Firebase接続migration、サービス編集UIをschema v10で実装。
- Phase C: メンション後の確認、payload preview、AI名義Continuation、request IDによる二重送信防止をschema v11で実装。
- Swift Testing 71件成功。Debug Simulator build成功。
- 初回XCUITestで検索初期状態の要素種別固定と検索結果遷移が失敗したため、identifierを要素種別非依存で待機し、検索結果を明示destinationへ変更した。修正後はiPhone SE Simulatorで全14件成功。

## 次の作業

Simulator XCUITestとFirebase Debug実通信、Release App Attest通信を確認する。
