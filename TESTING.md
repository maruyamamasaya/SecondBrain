# Testing

## Test Strategy

UI非依存のドメイン／永続化／ExportはSwift PackageとしてLinux/macOS共通で検証します。SwiftUI appとXCUITestはmacOS/XcodeのSimulatorで検証します。

## Unit / Persistence Test

```bash
swift test
```

入力境界（空、trim、140／141文字）と共通`ThoughtTimeline.post`、Unicode、SQLite順序、soft delete、再読込、本文検索、タグ、Personaのv11 migration・公開ID検証・作成・更新・無効化・設定・任意投稿者関連・不正投稿者時rollback・AI接続分離・AI投稿preview・140文字超過時非保存・メンションatomic保存・AI返信Continuationのatomic保存とidempotency、Review、分析、backup、Exportを検証します。Firebase SDKと実通信はUnit Testに含めません。

## UI Test

`AiTextAppUITests`は既存Timeline Composerに加え、Quick Captureの起動、空draft、自動focus、trim投稿、Timeline即時反映、単一投稿、空／141文字拒否、空キャンセル、入力中破棄確認・継続時保持、投稿失敗時の画面・draft保持を検証します。custom URLのcold launch／foreground受信、通常起動ではTimelineのままであること、route dismiss後の消費も検証対象です。本文検索、Thoughtに紐づくタグ、Continuation、Daily Summaryのflowも維持します。

ローカル分析UIは「Timelineで1件投稿 → 分析を開く → 今日／7日／30日／活動日／活動日平均 → 日別カレンダーの今日が1件」をXCUITestで確認します。日別カレンダーの配置・濃淡・今日の枠線、locale曜日、時間帯、タグEmpty State、Continuation説明はSimulatorで目視とVoiceOver確認も行います。

```bash
xcodebuild -project AiTextApp.xcodeproj -scheme AiTextApp \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' test
```

キーボード表示、140文字、複数件、Dynamic Type、Light/Dark mode、VoiceOver label、Share Sheet保存先に加え、AI要約の送信確認／loading／失敗／再試行／Mock表示／再要約、要約履歴の新しい順・最新表示・期間切替、Files／iCloud Drive picker、security-scoped bookmarkの再起動後再利用、保存先失効時表示、Restore後の再起動をSimulator／実機で手動確認します。

## Build

```bash
xcodebuild -project AiTextApp.xcodeproj -scheme AiTextApp \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' build
```

最新標準iPhone名は`xcrun simctl list devices available`で確認してdestinationへ指定します。

WidgetはXcodeで`AiTextAppWidget` targetのcompile／署名、systemSmall preview、ホーム画面への配置を確認します。Widget全体タップからcold launch／foregroundの両方でQuick Captureが開き、入力欄がfocusされることを確認します。ExtensionのSources／Link Binary With LibrariesにThoughtCore、SQLite、Firebaseが含まれず、App Groups entitlementがないことも確認します。

## Firebase Integration / Device

Daily SummaryはThoughtがある日／ない日、要約済み状態、過去月移動、送信前payload、構造化各Section、再起動後の復元を確認します。実通信ではJSON応答が保存され、タグ／Thought／Continuationが変更されないことを確認します。

XcodeでFirebase package resolveとapp targetのcompileを行った後、Debug Providerを登録したSimulator、App Attestを登録した実機の順で明示送信を確認します。成功時のSQLite provider／model、未設定plist、未登録Debug token、App Check拒否、offline、429／quota、その他API、空応答を確認します。Console設定や実APIを必要とする検証は通常のUnit Testへ組み込みません。

## General Checks

```bash
git diff --check
git status --short
git ls-files
```
