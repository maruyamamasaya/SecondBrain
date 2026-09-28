# Session: SecondBrain文書整合と次期機能設計準備

- Date: 2026-09-28

## Request

SecondBrainのProduct VisionをREADMEを含む既存文書へ反映し、実装との乖離、とくに外部APIの有無を修正する。次期機能の設計準備まで進める。

## Investigation

- Git rootが`C:/Users/m-maruyama/Development/SecondBrain`であることを確認した。
- `CURRENT.md`、`ARCHITECTURE.md`、`CODEMAP.md`、`TESTING.md`、`OPERATIONS.md`、`AGENTS.md`、recent sessions、Decision、主要entry pointを照合した。
- 現行実装はFirebase AI Logic / App Check、OpenAI Responses API、GitHub APIを利用する一方、`AGENTS.md`には「外部APIなし」、READMEにはPhase 1-Aと記録されていた。
- `SQLiteThoughtRepository.schemaVersion`は20、`MainTabView`はHome／Mentions／AI機能／振り返り／Profileの5タブであることをコードから確認した。
- 最新Mac検証は`ExternalBrainCache.journalEntries()`のSwift 6.3型推論errorでcompile停止しており、週間振り返り追加後のtest／buildは未完了だった。

## Changes

- READMEをSecondBrainの現行Vision、実装済み機能、外部API、Apps / Tools構想を示す入口へ更新した。
- `AGENTS.md`のProject ContextをAI Persona、Knowledge、External Brain、外部APIを含む現状へ更新した。
- `CURRENT.md`をschema v20、外部APIの現在地、最新compile blocker、直近優先順位へ更新した。
- `ARCHITECTURE.md`の5タブ構成とCurrent Product Boundaryを実装に合わせた。
- `CODEMAP.md`、`TESTING.md`、`OPERATIONS.md`の古い前提を修正した。
- `NEXT_FEATURES.md`を追加し、次期候補比較、Apps / Tools Hub v1のscope／non-goals、domain draft、security、implementation slices、Open Decisionsを整理した。

## Files Changed

- `README.md`
- `AGENTS.md`
- `CURRENT.md`
- `ARCHITECTURE.md`
- `CODEMAP.md`
- `TESTING.md`
- `OPERATIONS.md`
- `NEXT_FEATURES.md`
- `sessions/2026-09-28-secondbrain-document-alignment.md`

## Validation

- `rg`で旧前提（外部APIなし、Phase 1-A、schema v19、Searchタブ、未設定App icon）を検索し、主要文書から除去済みであることを確認した。
- `git diff --check`成功。
- Windows環境にSwift toolchainがないため、`swift test`とXcode buildは未実行。文書のみの変更であり、既知のMac compile blockerは解消していない。

## Result

実装済み事実、Product Vision、未実装の次期構想を文書上で分離し、外部API利用を主要文書へ反映した。Apps / Tools Hub v1は設計準備までで、採用Decisionやコード実装は行っていない。

## Remaining Issues

- Swift 6.3 compile blockerの修正とMac検証baselineの回復。
- schema v19→v20 migration testの追加。
- Apps / Tools Hub v1の入口、catalog初期データ方式、Local Web許可範囲の決定。
