# 0009: Apps / Tools catalogをCoreから分離して正本SQLiteへ保存する

- Status: Accepted
- Date: 2026-09-28

## Context

SecondBrainを自作アプリ、Webツール、Local Web、外部サービスへの統一入口へ拡張する。Thoughtを中心とする既存Coreを壊さず、App間データ共有やAI操作へscopeを広げない最小基盤が必要である。

## Decision

- Thought、AI、Knowledge、InsightsはSecondBrain Coreとして維持し、ThoughtをApps catalogへ登録しない。
- Apps / Toolsは不変UUIDを持つ`SecondBrainApp`で表現し、`kind`と`launchTarget`を分離する。
- Domain生成時にname、sortOrder、URL、scheme、Local Web host、kind／target整合性を検証する。
- catalogはschema v21の`secondbrain_apps`へ保存する。Thought／Persona／Knowledge tableへの外部キーを持たせない。
- `SecondBrainAppRepository`をDomain境界とし、現行の正本DBを所有する`SQLiteThoughtRepository`が実装する。
- sample Appはtest fixtureだけに置き、本番DBを自動seedしない。
- catalogは正本SQLiteの完全Backup / Restore対象に含める。
- UI、Native route解決、URL起動、到達確認、WebView、App間データ共有、AIによるApp操作はこのDecisionの実装範囲に含めない。

## Reason

既存SQLiteのmigration、health check、rolling backup、外部完全Backup / Restoreを再利用しながら、Apps catalogの障害や削除をCoreデータへ波及させないためである。kindとtargetを分けることで表示分類と起動方式を混同せず、将来の起動方式追加にも対応できる。

## Alternatives

- UserDefaults: 少量データには簡単だが、一覧順序、更新、完全Backup / Restore、schema検証の境界が既存DBと分かれるため採用しない。
- 別SQLiteファイル: 障害分離は強いが、Backup / Restoreとtransaction運用が増えるためv1では採用しない。
- bundled catalogの自動seed: すぐ一覧を表示できるが、ユーザーの正本データとsampleを混同するため採用しない。
- `kind`から起動先を推測: modelは小さくなるが、ExternalのHTTPS／Deep Linkなど一対多の関係を安全に表現できないため採用しない。

## Consequences

- schemaはv20からv21へ上がり、空の`secondbrain_apps` tableが非破壊追加される。
- App削除は対象IDのcatalog行だけをhard deleteし、Core tableを変更しない。
- 同じ表示名やURLを持つ複数environmentを許容し、UUIDで識別する。
- Local WebのHTTPはlocalhost、`.local`、private／loopback／link-local addressに限定する。
- SwiftUIと実際の起動時にもDomain policyを再利用または再検証し、保存済み表示名だけで接続先を隠さない必要がある。
- Windows先行実装のため、Mac/Xcode compile、Swift Testing、schema migration、Backup / Restore、実機ネットワーク確認が残る。
