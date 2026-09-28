# Session: Apps / Tools Hub v1 Domain／Persistence

- Date: 2026-09-28

## Request

SecondBrainの次期機能としてApps / Tools Hub v1を開始し、Windowsで安全に進められる共通Domain、validation、SQLite Repository、sample fixture、test仕様、Mac検証引継ぎを実装する。既存Core機能を変更せず、UIは最小限または後回しとする。

## Investigation

- Git root、`CURRENT.md`、`AGENTS.md`、`ARCHITECTURE.md`、`CODEMAP.md`、`TESTING.md`、`OPERATIONS.md`、既存Decisionを確認した。
- `SQLiteThoughtRepository`が正本DB、migration、health check、rolling backup、外部完全Backup / Restoreを所有し、schema v20であることを確認した。
- Swift Packageは`ThoughtCore/`と`ThoughtCoreTests/`配下を自動収集するが、Xcode app targetは`project.pbxproj`へのsource追加が必要だった。
- Windows環境に`swift`と`sqlite3` CLIがなく、既知のSwift 6.3 compile blockerも未解消である。

## Changes

- `SecondBrainApp`、`SecondBrainAppKind`、`SecondBrainAppLaunchTarget`、閉じたNative feature、Repository protocolを追加した。
- name、sortOrder、日時、HTTPS、Local Web host、危険scheme、kind／target組み合わせをDomain生成時に検証する。
- HomeMuseum、Baby Media、GitHub Monitorを安定UUIDのtest fixtureとして追加し、本番DBはseedしない。
- schema v21へ独立`secondbrain_apps` tableとorder／favorite indexを追加した。Core tableへのForeign Keyは持たない。
- SQLite CRUD、安定順、favorite、作成日時不変、duplicate／not found error、rolling backup接続を追加した。
- validation、fixture非seed、CRUD、v20→v21 migrationでThoughtを保持するtestを追加した。
- Xcode app targetへCore sourceを追加した。SwiftUI、URL起動、WebViewは追加していない。
- Decision 0009と主要設計／検証文書を更新した。

## Files Changed

- `ThoughtCore/SecondBrainApp.swift`
- `ThoughtCore/SQLiteThoughtRepository.swift`
- `ThoughtCoreTests/SecondBrainAppTests.swift`
- `ThoughtCoreTests/DailySummaryTests.swift`
- `ThoughtCoreTests/ExternalBrainTests.swift`
- `ThoughtCoreTests/ThoughtTimelineTests.swift`
- `ThoughtCoreTests/WeeklyReviewTests.swift`
- `AiTextApp.xcodeproj/project.pbxproj`
- `decisions/0009-apps-tools-catalog-boundary.md`
- `README.md`
- `CURRENT.md`
- `ARCHITECTURE.md`
- `CODEMAP.md`
- `TESTING.md`
- `NEXT_FEATURES.md`
- `MAC_VALIDATION.md`

## Validation

- `git diff --check`: 成功。
- stale schema version／旧未実装表記の`rg`確認: 対応済み。
- Xcode project内の新規PBX build reference／file reference参照数を確認した。
- **Windowsで実装済み／Mac/Xcode compile未確認／Swift Testing未実施／実機確認未実施**。
- `swift test`、Xcode build、SQLite test実行はtoolchain不在のため未実施。

## Result

Apps / Tools Hub v1のDomainと正本SQLite Persistence、test仕様を追加した。ThoughtはAppsへ含めずCoreのまま維持し、App catalogは既存Core tableと独立させた。UIと実際の起動は次sliceへ残した。

## Remaining Issues

- Swift 6.3 compile blockerを解消し、全Swift TestingとXcode buildを実行する。
- schema v19→v20とv20→v21を連続確認し、外部Backup / Restore回帰を実行する。
- Apps入口を決め、一覧／編集UI、起動時policy、URL／Local Web／Deep Link／Native routeを実装・実機確認する。
