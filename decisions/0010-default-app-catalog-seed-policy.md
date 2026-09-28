# 0010: Default Catalogをmissing-onlyで登録し削除履歴を保持する

- Status: Accepted
- Date: 2026-09-28
- Supersedes: 0009の「本番DBを自動seedしない」判断

## Context

Apps / Tools Hubを実用的な入口として開始するため、ユーザーが実際に利用する4つのWebアプリを正式な初期catalogとして提供する必要がある。一方、起動のたびに初期値をupsertすると、ユーザーが変更した名前、URL、お気に入り、表示順を上書きし、意図して削除したAppも復活させてしまう。

## Decision

- `SecondBrainDefaultApps.catalogVersion = 1`として、Shared Memo、My Wiki、Study、Toolを固定UUIDで定義する。
- Default CatalogはPreview／test用の`SecondBrainAppFixtures`と分離する。
- Repository初期化時に、Default App IDごとの適用履歴を確認してmissing-only seedする。
- 適用履歴がなく、同じIDのAppも存在しない場合だけ初期値を挿入する。
- 適用履歴がなくても同じIDのAppが既に存在する場合は、その内容を変更せず適用履歴だけを記録する。
- 一度適用したIDはAppが削除されても再登録しない。削除をユーザーの意思として保持するため、適用履歴に`secondbrain_apps`への外部キーを持たせない。
- schema v22で`secondbrain_default_app_seed_history(app_id, catalog_version, seeded_at)`を追加し、App挿入と履歴記録を同一transactionで行う。
- catalog versionは各App IDがどのcatalog版で導入されたかを記録する。将来の版では新しい固定IDだけを追加し、過去のDefault Appを上書きしない。
- App catalogと適用履歴は正本SQLiteの完全Backup / Restore対象とする。

## Reason

「初回から使える入口」と「ユーザーが所有するcatalog」の両方を守るためである。App本体の有無だけをseed判定に使うと削除を欠損と区別できないため、独立した適用履歴が必要になる。固定UUIDにより再実行とmigrationで同じAppを安定して識別できる。

## Alternatives

- 毎回upsertする: 初期値更新は容易だが、ユーザー編集と削除を破壊するため採用しない。
- Appがなければ毎回insertする: 編集は守れるが、削除したDefault Appが復活するため採用しない。
- UserDefaultsにseed済みversionを1つだけ保存する: DBのBackup / Restoreと状態が分離し、App単位の将来追加や復元を正しく判断できないため採用しない。
- Preview fixtureをそのままseedする: 実在Appの正式catalogと開発用sampleを混同するため採用しない。

## Consequences

- schemaはv21からv22へ上がる。既存`secondbrain_apps`とCore tableは変更しない。
- 新規DBとv21以前からのmigration後にはDefault Catalog v1が適用される。
- 既存の同一固定UUID行は上書きされず、履歴だけが追加される。
- Default Appの削除はhard deleteのままだが、seed履歴がtombstoneとして残る。
- catalog定義を変更しても既存ユーザーのAppへ自動反映しない。必要な更新機能は別の明示的な設計判断とする。
- Windows先行実装のため、Mac/Xcode compile、Swift Testing、migration、完全Backup / Restoreは未確認である。
