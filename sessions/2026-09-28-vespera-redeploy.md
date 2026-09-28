# Vespera向け署名更新と再デプロイ

- 対象: Vespera（iPhone 17e）
- `com.example.AiTextApp`用の開発プロビジョニングプロファイルがMac上に存在せず、CLIの自動署名buildは`No Accounts`／`No profiles`で失敗した。
- Xcodeの登録済みApple Accountからmanual profileを更新し、VesperaをRun destinationにしたDebug実機buildで新しいAiTextApp用プロファイルを生成した。
- 現在の作業ツリーを署名・buildし、既存アプリを削除せずVesperaへ上書き導入した。
- Xcodeで`Finished running AiTextApp on Vespera`を確認し、`devicectl`でも`com.example.AiTextApp`の導入と起動成功を確認した。
- ソースコード、設定、端末内データは変更・削除していない。既存の未コミット変更もそのまま保持した。
- `swift test`はcompileに成功し145件を実行したが、週間振り返りのSQLite round-trip 1件と既存DB migration 3件が失敗した（計5 issue）。migration 3件は`weekly_summaries already exists`、round-trip 1件はWeekly Summary／Planの等価比較失敗。今回のExternal Brain型推論修正とは別領域のため、この作業では変更していない。
- UI test／Simulatorは実行していない。新規XCTestDevices 0件、削除0件。
