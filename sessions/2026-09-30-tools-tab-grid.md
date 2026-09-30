# Toolsタブと振り返り導線

日付: 2026-09-30

## 要求

- App / Toolを3列の正方形タイルで表示する。
- 下部メニューバーの「振り返り」をHome右上へ移す。
- 下部メニューバーへ「ツール」を追加する。

## 変更

- `ThoughtStore`から`SecondBrainAppRepository`のcatalogを読み込み、UIテスト用のMemory repositoryではDefault Catalogを使用するようにした。
- 下部5タブをHome／Mentions／AI機能／Tools／Profileへ変更した。
- Tools画面へ3列の正方形タイル、Empty State、Native route、外部URL起動、起動失敗Alertを追加した。
- Home右上に振り返りボタンを追加し、既存のサマリー／日記／週間振り返り／分析画面を同じNavigationStack内で開くようにした。
- UIテストのタブ期待値、振り返り導線、Default Catalogタイル確認、Theme screenshot対象を更新した。
- `CURRENT.md`、`ARCHITECTURE.md`、`CODEMAP.md`、`TESTING.md`、`NEXT_FEATURES.md`を現行構成へ合わせた。

## 検証

- `git diff --check`: 成功（改行コード変換予定のwarningのみ）。
- staleな`InsightsView`／`insightsTab`／振り返りタブ参照が残っていないことを`rg`で確認した。
- Windows環境にSwift toolchainがないため、Swift compile、Xcode build、UI test、Simulator目視確認は未実施。
- Windowsから遠隔Macと5G接続中のVesperaとのXcode接続を確認できないため、実機デプロイは試行せず未実施課題として`MAC_VALIDATION.md`へ残した。
- Xcode testを実行していないため、`XCTestDevices`の作成・削除は0件。Mac側容量は未確認。

