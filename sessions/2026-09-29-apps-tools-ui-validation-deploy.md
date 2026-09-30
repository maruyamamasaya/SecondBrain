# Apps / Tools UI・migration修正・Mac検証・Vespera導入

## 対象

- Swift Testing compile errorと週間Review／migration失敗の修正
- Apps / Tools Hub v1の一覧・編集UI、安全な起動policy
- Mac／Simulator検証とVesperaへのDebug上書き導入

## 実装

- Swift Testingのthrowing expressionを`#require`から分離した。
- schema v20〜v22のtable／index作成を`IF NOT EXISTS`化し、`user_version`と実tableがずれた既存DBでも既知schemaを非破壊補修できるようにした。
- Weekly Summary／Plan round-trip testの日時を固定し、SQLiteの秒精度と比較条件を一致させた。
- schema v19→v22 fixtureを追加し、Thought、Weekly Summary、Default Catalogの保持を検証した。
- AI機能タブへApps / Tools一覧を追加し、お気に入り／全件、追加、編集、削除、SF Symbols、Native／Web／Local Web／External設定を実装した。
- 起動時にDomain modelを再構築して再検証し、外部URLは実host／endpoint／schemeを確認後だけ`openURL`へ渡すようにした。
- Memory repositoryにもDefault CatalogとCRUDを実装し、XCUITestの実構成をSQLite実装と揃えた。

## 検証

- 環境: Xcode 26.6 (17F113)、Swift 6.3.3、iPhone SE (3rd generation) iOS 17.4、Vespera iPhone 17e。
- `swift test`: 13 suites、154 tests、0 issue。
- Debug Simulator build: 成功。
- XCUITest `testAppsToolsShowsDefaultsConfirmsDestinationAndAddsWebApp`: 成功。Default Catalog 4件、Shared Memoの実endpoint確認、Web App追加を確認した。
- Vespera向けDebug署名build: 成功。bundle ID `com.example.AiTextApp`、既存development profileを使用。
- Vesperaへの上書きinstall: 成功。アプリ削除と端末内データ削除は行っていない。
- launchは2回試行したが、どちらも端末ロックによりCoreDeviceから拒否された。上書きinstallは完了しており、Vesperaのロック解除後の起動確認だけが残る。
- 既存warning（`Date.init`のSendable変換、未使用値、不要な`try`）は残るが、新規build errorはない。

## ストレージ

- UI test前の`~/Library/Developer/XCTestDevices`: 既存1フォルダ、3.5G。
- 終了時も同じ既存1フォルダ、3.5G。新規作成0件、削除0件。

## 残課題

- 週間Summary／Planと日記表示の生成を伴う手動確認。
- Apps / Toolsから実際のHTTPS／Local Web／Deep Link／Native routeを開く実機操作。
- 全XCUITest、最新標準iPhone、Dynamic Type、Dark Mode、VoiceOver。
