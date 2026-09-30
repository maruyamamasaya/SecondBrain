# 0011: Apps / ToolsをAI機能タブへ置き外部起動前に実endpointを確認する

- Status: Accepted
- Date: 2026-09-29

## Context

Apps / Tools HubのDomainとcatalogは実装済みだったが、既存5タブ内の入口、icon表現、Native／外部URLの起動責務が未決定だった。6番目のタブは小型iPhoneの可読性を下げ、Profile配下では日常利用の入口として深すぎる。保存時検証だけでは、将来のmigrationや破損データをそのまま起動へ渡す危険も残る。

## Decision

- 既存5タブを維持し、AI機能タブへ独立した「Apps / Tools」sectionを置く。
- v1のiconはSF Symbols名だけを保存し、remote imageや任意ファイルは扱わない。
- Native routeは`SecondBrainNativeFeature`の閉じたenumに限定し、AI投稿依頼、Knowledge、Insightsへ遷移する。
- Web、Local Web、Externalは保存済み値を起動時に`SecondBrainApp`として再構築し、Domain validationを再実行する。
- 外部起動前に、Webはhost、Local Webはhostとport、Deep Linkはschemeを含む実endpointを確認dialogへ表示する。確認後だけSwiftUIの`openURL`へ渡す。
- URL到達性の常駐監視、WebView、認証情報保存はv1へ含めない。

## Reason

AI機能タブは既にPersona、Provider、External Brain、Knowledgeを束ねるワークスペース入口であり、Thought中心のHomeと5タブ構成を変えずにAppsを発見できる。SF Symbols限定はiOS 16対応とbackupの単純性を保つ。起動時再検証と実endpoint確認により、保存時以降の不整合や外部遷移の誤認を防ぐ。

## Consequences

- `SecondBrainAppsView`が一覧、追加、編集、削除、起動確認を所有する。
- `ThoughtStore`は`SecondBrainAppRepository`をpresentation stateへ接続する。
- `SecondBrainAppLaunchPolicy`は純粋な判定を返し、実際の画面遷移と`openURL`はapp layerに残す。
- 検索、種別filter、recent、実URL／Local Web到達確認、Dynamic Type／VoiceOver／Dark Modeの手動検証は後続とする。
