# Next Feature Design Preparation

最終更新日: 2026-09-28

Apps / Tools Hub v1は採用され、Domain／PersistenceをWindows先行で実装しました。この文書は残るUI／起動処理とMac検証の計画を管理します。現在の実装状態は`CURRENT.md`、実装済み構成は`ARCHITECTURE.md`を正本とします。

## Product Direction

SecondBrainはThoughtを入口として、AI、Knowledge、Insights、Apps / Toolsへ接続する個人用ワークスペースを目指します。既存機能を維持しながら、アプリ自身にすべてを再実装せず、異なる実装方式のツールを共通の体験で見つけて起動できる境界を追加します。

## Macでの検証開始条件

WindowsではiOS依存を避けてDomain／Persistenceを先行しました。Macへ戻ったら、UI実装前に現行main相当の検証可能なbaselineを回復します。

1. `ExternalBrainCache.journalEntries()`のSwift 6.3型推論compile blockerを解消する。
2. `swift test`を完走し、週間振り返り、schema v19→v20とv20→v21のmigration、日記のDraft／active重複抑制、Apps CRUD／validationを確認する。
3. Debug Simulator buildを成功させ、週間Summary／Planと日記表示を目視確認する。
4. `MAC_VALIDATION.md`へ結果とXCTestDevicesの作成・削除・残容量を記録する。

Apps / Tools Hub追加分は、**Windowsで実装済み／Mac/Xcode compile未確認／Swift Testing未実施／実機確認未実施**です。

## 次期候補の比較

| 候補 | 価値 | 現在の準備度 | 主なリスク | 推奨 |
| --- | --- | --- | --- | --- |
| Apps / Tools Hub v1 | SecondBrainを個人用アプリHubへ広げる最小の縦切り | Domain／SQLite実装済み、UI／起動未実装 | URL起動、Local Web到達性、UI配置 | 現在進行中 |
| AI Summary | Human限定Summaryと分離してAI側の活動を振り返る | 責務分離は既存設計に記録済み | Human／AIの意味混同、AI call増加 | 実利用ニーズ確認後 |
| Monthly Review | Daily／Weeklyの上位振り返り | Calendar・Summary基盤を再利用可能 | Weeklyとの重複、長大prompt | Weekly実利用後 |
| Analytics v2 | 記録から具体的な意思決定を支援する | ローカル集計基盤あり | 指標追加だけでは価値が弱い | 問いを定義できた場合のみ |

## 推奨する最小機能: Apps / Tools Hub v1

### 目的

登録済みの個人用アプリやツールを一覧・分類し、安全に起動できるようにします。ThoughtやKnowledgeとの深い連携は後続とし、v1では「見つける・状態を理解する・開く」に集中します。

### v1 Scope

- `SecondBrainApp`の登録、編集、削除、並び替え。
- `native`、`web`、`localWeb`、`external`の種別。
- 名前、説明、icon表現、起動先、category、お気に入り、表示順のローカル保存。
- Apps画面での一覧、種別filter、検索、詳細表示。
- `https` URLの明示起動と、起動前にhostを確認できる表示。
- Local Webは到達確認を自動常駐監視せず、ユーザー操作時だけ試行する。
- Nativeはv1で既存SecondBrain画面への定義済みrouteだけを許可する。

### Non-goals

- 外部Webアプリの認証情報、cookie、tokenの保存。
- 任意JavaScriptの実行、Webコンテンツの改変、埋め込みブラウザの独自実装。
- アプリの自動発見、LAN scan、バックグラウンドのhealth check。
- App Store型の配布、第三者向けmarketplace、複数利用者共有。
- Thoughtから外部アプリへデータを自動送信するdeep integration。
- 既存の5タブ構成を直ちに6タブへ変更すること。入口配置はprototypeで比較する。

## Implemented Domain

`SecondBrainApp`は不変UUID、name、description、icon、kind、launchTarget、category、isFavorite、sortOrder、createdAt、updatedAtを持ちます。`SecondBrainAppKind`と`SecondBrainAppLaunchTarget`は分離し、Native routeは`SecondBrainNativeFeature`の閉じたenumです。ThoughtはNative Appとして登録せずSecondBrain Coreに維持します。

launch targetは`nativeFeature`、`webURL`、`localURL`、`deepLink`です。URL文字列はmodel生成時に検証し、不正なmodelをRepositoryへ渡せない構造にしています。

## Proposed Boundaries

```text
Apps UI
  -> AppCatalogStore（presentation state）
    -> SecondBrainAppRepository
      -> SQLiteThoughtRepository（secondbrain_apps table）
    -> AppLaunchPolicy
      -> Native route resolution
      -> External URL validation / open request
```

- App catalogはThought、Knowledge、AI生成履歴と別tableに分離し、Repository protocolだけを共有DB実装へconformさせる。
- `AppLaunchPolicy`は純粋なdomain判定とし、実際の`openURL`はapp layerに置く。
- icon画像を扱う場合も初期版はアプリ内symbolまたは小さなローカルassetに限定し、remote image fetchを必須にしない。
- App catalogは正本DBのschema v21へ追加したため、既存の完全Backup / Restore対象に含まれる。

## UI検討

入口は次の2案をprototypeで比較します。

1. AI機能タブを「ワークスペース」に拡張し、AIとAppsをsectionで分ける。
2. Profile配下にAppsを追加し、利用頻度が確認できてから主要タブへの昇格を判断する。

6番目のタブ追加は小型iPhoneでの可読性と既存5タブの優先順位に影響するため、v1の前提にしません。ホームへのApp shortcut配置も、Thought中心という原則を壊さないか実利用で評価します。

## Security / Privacy Checklist

- `https`を既定とし、`http`はLocal Webとして明示的に区別する。
- `javascript:`、`data:`、`file:`、資格情報埋め込みURLを拒否する。
- Local Webのhostとportを起動前に表示し、外部送信と誤認しない文言を用いる。
- catalogへsecretを保存しない。必要な認証は対象アプリ側の責務とする。
- URL、起動履歴、到達失敗をAI promptへ自動投入しない。
- 外部起動は常にユーザー操作を起点とし、自動redirectを行わない。

## Implementation Slices

1. 完了（Mac未検証）: `SecondBrainApp`、validation、sample fixture、URL policy test。
2. 完了（Mac未検証）: schema v21の独立SQLite table、CRUD／並び順／お気に入り、v20→v21 migration test。
3. 次: Catalog UIの一覧、Empty State、追加／編集／削除。検索／filterはデータ量を見て追加する。
4. 次: Native routeとExternal URLを分離し、起動前host表示と確認可能な失敗表示を追加。
5. Accessibility / verification: Dynamic Type、VoiceOver、Dark Mode、小型iPhone、offline Local Web。
6. 実利用後にThoughtからの共有、favorite、recentなどの次段階を判断する。

## Acceptance Draft

- 既存Thought、AI、Knowledgeの保存・表示を変更せずAppを登録できる。
- 不正または危険なURLを保存・起動しない。
- 削除は対象App IDだけをhard deleteし、Thought／AI／Knowledgeへ影響しない。
- 同じ表示名を許容し、内部IDで識別する。重複URLの扱いは実装前に決める。
- 外部起動の失敗がThoughtの保存やアプリ起動を妨げない。
- 新schemaから旧schemaへ戻せない前提を明示し、migration testと外部Backup復元testを通す。

## Open Decisions

UI／起動実装前に未決定事項を決め、長期的な制約になる場合だけ`decisions/`へ記録します。

1. Appsの入口を既存5タブのどこへ置くか。
2. 決定済み: サンプルはtest fixtureだけに置き、本番DBを自動seedしない。ユーザー登録UIは次sliceで作る。
3. 決定済み: `http`はLocal Webだけで許可し、localhost、`.local`、private／loopback／link-local IPに限定する。
4. App iconをSF Symbolsだけに限定するか、ローカル画像を許可するか。
5. 決定済み: schema v21の正本SQLiteへ置き、外部完全Backup / Restore対象に含める。
6. 決定済み: App IDだけを一意とし、同じtoolの複数environmentを表現できるよう重複URL／表示名を許可する。

## Design Start Checklist

- [ ] 現行compile blockerとMac検証を完了した。
- [ ] Open Decision 1（Apps入口）を決めた。
- [x] SwiftUI `App`との混同を避けて`SecondBrainApp`と命名した。
- [x] schema v21変更とv20→v21 migration testを追加した。
- [x] Domain保存時のURL threat modelを実装した。起動時の再検証と失敗時UXは未実装。
- [ ] v1の画面wireframeを小型iPhone／Dynamic Type前提で確認した。
- [ ] 実装開始時に必要なら正式なDecisionを追加した。
