# Operations

この文書はSecondBrainの現行iOSアプリ`SecondBrain`の開発、外部サービス、データ保全を扱います。現在利用する外部APIはFirebase AI Logic / App Check、OpenAI Responses API、GitHub APIです。Apps / Tools Hubはcatalogと起動UIまで実装済みですが、外部Appの認証情報は保存・管理しません。

## Local Development

`AiTextApp.xcodeproj`をFirebase AI Logicが要求するXcode 26.2以降で開き、`AiTextApp` schemeと任意のiPhone Simulatorを選んで実行します。iOS 16.0以降が対象です。通常起動はFirebaseクライアントを使い、Firebase未設定時は外部送信せず設定エラーを表示します。UIテストはMemory repositoryとMock AIクライアントを使います。

## Local Data

初回起動時にApplication Support内の`ThoughtTimeline/thought-timeline.sqlite3`と親ディレクトリを自動作成します。同じ場所に旧`thoughts.json`があれば一度だけ取り込み、成功後もバックアップとして残します。データをリセットするにはSimulatorからアプリを削除してください。

## Build / Test

Xcodeの`AiTextApp` shared schemeでbuildします。CLIコマンドとCore testは`TESTING.md`を参照してください。

## Environment / External Services

### Persona External Brain

設定 > External Brainで単一GitHub Repositoryのowner、repository、branchとread-onlyのfine-grained tokenを設定し、「今すぐ同期」を実行します。tokenはKeychainにのみ保存され、SQLite、Export、backup、ログへ含めません。Persona編集でExternal BrainをONにし、同Repository内のAGENT.md pathと最大参照数を指定します。cacheは`Application Support/ExternalBrain`配下の派生データで、同期失敗時は前回cacheを使い、cacheがなければExternal BrainなしでAI Replyを続行します。

Firebase Apple SDKはSwift Package Managerで12.17.0以降を指定し、app targetへ`FirebaseCore`、`FirebaseAILogic`、`FirebaseAppCheck`をリンクします。APIキーをSwiftコードへ追加しません。

### Firebase AI Logic / App Check接続

1. Firebase Consoleで実際のbundle identifierを持つiOS appを登録し、Firebase AI LogicのGet startedからGemini Developer APIを有効化する。
2. Consoleから`GoogleService-Info.plist`を取得してリポジトリrootへ配置する。app targetの`Copy Optional Firebase Configuration` build phaseが、存在する場合だけapp bundleへcopyする。このファイルは`.gitignore`対象で、各開発環境へ安全に配布する。
3. Xcodeでpackageをresolveし、`FirebaseCore`、`FirebaseAILogic`、`FirebaseAppCheck`がapp targetへリンクされていることを確認する。
4. Debug buildを起動する。Debug configurationはApp Attest entitlementを持たず、Personal Teamでも署名可能にする。`AppCheckDebugProviderFactory`が出力するDebug tokenをFirebase ConsoleのApp Check > Manage debug tokensへ登録する。tokenはScheme、ソース、文書へ記録・コミットしない。
5. Release buildは`AppAttestProviderFactory`と`AiTextApp.entitlements`のproduction App Attest環境を使う。ConsoleでApp Attestを登録し、実機で成功を確認してからenforcementを段階的に有効化する。
6. AI PersonaでGeminiを選び、投稿・手動返信・自動返信が`gemini-3.7-flash`のlowで生成されることを確認する。Daily SummaryはOpenAI固定のため、このGemini接続確認には使わない。

`GoogleService-Info.plist`がない場合は起動を継続し、AI送信時に未設定エラーを表示します。App Check、429／quota、network、その他API、空応答はユーザー向けの別エラーへ変換します。Firebase ConsoleのenforcementはDebug tokenと実機App Attestの確認後に有効化してください。

### OpenAI Responses API接続

この接続は、自分のiPhoneだけへXcodeから導入し、TestFlight／App Store／第三者配布を行わない期間だけの暫定運用です。設定 > AIのSecureFieldへOpenAI API keyを貼り付け、「OpenAI API keyを保存」を押します。キーは`WhenUnlockedThisDeviceOnly`のKeychainへ保存され、iCloud Keychain同期、端末移行、UserDefaults、SQLite、Export、backup、ログ、Gitの対象にしません。OpenAI選択時はResponses APIへ`store: false`で直接通信します。AI Personaの投稿・手動返信・自動返信は`reasoning.effort: low`、Daily SummaryとKnowledge Draftは`medium`を使います。Daily SummaryはOpenAI固定、Knowledge Draftは設定画面でProviderを選択します。Firebase Functions、Secret Manager、Blaze planは使用しません。

キーをコード、plist、Scheme environment、文書へ記録しないでください。端末の譲渡、紛失、侵害の疑いがある場合は設定画面から削除し、OpenAI側でも直ちに失効・再発行します。アプリをTestFlight／App Storeで配布する、第三者へ渡す、複数端末・複数利用者へ広げる、または継続運用へ移る前に、直接接続を停止してAPI keyをバックエンドのSecret管理へ移します。移行先には利用者認証、端末／アプリ検証、rate limit、model allowlist、入力上限、監視と利用停止手段を設けます。

## Deploy

CI/CD、配布用bundle identifier、code signing、provisioning、TestFlight/App Store設定は未構成です。

2026-09-30のToolsタブ／振り返り導線はWindowsで実装され、Swift compile、Xcode build、UI Test、Simulator確認、Vesperaへの実機デプロイは未実施です。Vesperaへの開発版導入は、署名情報を持つMacから端末が`devicectl`／XcodeのRun destinationとして接続可能であることを確認してから、既存アプリを削除せず上書きします。5G越しで端末を認識できない場合は試行せず、同一Wi-FiまたはiPhone側拠点のMacを使用します。

## Backup / Export

正常なDB初期化後とThoughtの書き込み後には、`thought-timeline.sqlite3.backup.1`（最新）と`.backup.2`（ひとつ前）をSQLite Online Backup APIで更新します。自動復元は行いません。DB初期化失敗時はアプリを削除せず、正本を退避してからバックアップコピーを復元します。調査なしに新規DBで上書きしないでください。

起動時はmigration後にDB health checkを実行します。Consoleの`Thought database initialization failed`には`quick_check`、`foreign_key_check`、または不足schema名が記録されます。UIに「保存データの整合性確認に失敗しました」と表示された場合は、アプリの削除・再インストール・空DB作成を行わず、先に正本DBと`.backup.1`／`.backup.2`を保全してください。既知の旧`thought_relations`制約だけは、既存Relationを保持してschema v15へ自動補修します。

通常の持ち出しは画面右上のExportからMarkdown（人間向け）またはJSON（原文バックアップ／将来Import向け）を選び、標準Share SheetでFilesやAirDropへ保存します。Export失敗はSQLiteとComposerを変更しません。

Daily Summaryはアプリ内の日別振り返りとしてSQLiteと外部完全バックアップに含まれます。要約済みの過去日も「この日を再生成」から最新promptで更新できます。新しい生成が失敗した場合は旧Summaryを保持し、成功時だけ同日のSummaryを置き換えます。旧History Reviewの期間要約Export導線は現在提供しません。

### External Full Backup

画面右上のバックアップ管理から「バックアップ保存先を選択」を開き、Files／iCloud Drive上のユーザー管理フォルダを選びます。アプリはsecurity-scoped bookmarkを保存し、そのフォルダ内だけに`AiText Backup/latest`と`previous`を作ります。「今すぐバックアップ」はWAL利用中でも整合するSQLite Online Backup snapshotを一時directoryへ作り、manifest、サイズ、SHA-256、`PRAGMA integrity_check`、`user_version`を確認してから2世代を切り替えます。既存の無関係なファイルは削除しません。

アプリ削除前や端末移行前には、iCloud Driveなどアプリcontainer外を保存先にして「今すぐバックアップ」を実行し、成功表示と最終日時を確認してください。Application Support内の正本と`.backup.1`／`.backup.2`、保存先bookmark自体はアプリ削除で失われますが、Files上の`AiText Backup`は残ります。

### Restore

再インストール後はバックアップ管理の「バックアップから復元」から、`AiText Backup`、その親フォルダ、または`latest`／`previous`世代を選べます。アプリはmanifest形式、backup形式version、安全な相対ファイル名、symlink、SQLite存在・サイズ・SHA-256、open、integrity、schemaを検証した後にだけ確認画面を出します。「復元する」でApplication Supportのpending領域へcopy・再検証し、この時点では現DBを変更しません。

アプリを終了して次回起動すると、Repository接続前に現DBとWAL／SHMをrollback用へ退避し、pending DBを適用・再確認します。失敗時は退避した現DB一式を戻してエラーを表示します。検証または適用に失敗した場合はアプリを削除せず、外部backupの`previous`を選ぶか、バックアップフォルダの利用可能状態を確認してください。

## 日記・振り返りの保存

日記／デイリー・週間振り返りは編集画面の「保存する」で、端末保存後に設定済みGitHubへ送る。初回はUUID付きactive Markdownを`projects/aitextapp/knowledge/`に作り、再保存は同じpathを既知SHA付きで更新する。別途の承認・正式化・同期操作は不要。通常Knowledgeは従来どおり承認・正式化する。

失敗時は送信待ちとして端末へ残る。日記はカレンダー、振り返りは対象日／週またはサマリー一覧から「編集・保存する」で再送する。GitHubを外部で編集した場合は衝突として保留する。保存先を変更した場合は元のowner／repository／branchへ戻して再送する。自動的に別保存先へ移したり、外部編集を上書きしたりはしない。

## エラーログと重複候補

設定 > エラーログから、端末保存された最新200件の日時・処理・操作・分類・ログIDを確認する。保存場所はApplication Support/ThoughtTimeline/Diagnostics/operation-errors.json。本文、prompt、response、キー、Tokenは含まない。SQLite backupとは別の端末内診断ファイルであり、クラウドへ自動送信しない。

失敗時はポップアップの「次の対応」に従い、必要ならログIDで該当記録を確認する。重複候補は日記詳細に表示され、同日の日記追加／同本文の保存前に確認する。自動削除は行わない。
