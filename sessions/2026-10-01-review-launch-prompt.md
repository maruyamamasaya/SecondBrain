# 2026-10-01 起動時の振り返り案内

- Project Context: MATCH。既存のDaily Summary／Weekly Reviewへ接続。既存の未コミット変更を維持。
- 対象種別の回答がなかったため、前日デイリーと直近完了週の両方を対象とした。Human Thoughtあり・サマリー未作成だけをrepositoryから判定。読み込み失敗時は案内を抑制。
- MainTabViewで起動／バックグラウンドからの復帰時に案内Sheetを表示。期間ごとの作成導線とスキップを追加。スキップは暦日・種別のUserDefaults keyへ保存し、通常画面からの手動作成を維持。「あとで」とSheet dismissは次回復帰で再案内。
- 作成導線は既存の対象日／週画面と送信確認へ接続。自動API通信なし。
- swift test: 155件成功。Debug generic iOS署名なしbuild成功。git diff --check成功。実機導入・UI操作確認は未実施。
- 最初のbuildで日本語日付formatterのprivateアクセスを検出し、既存formatterを内部共有へ修正して再build成功。
- XCUITest未実行。テスト端末作成0／削除0。XCTestDevices残容量3.5G。検証DerivedDataは/private/tmp/aitextapp-review-build。
