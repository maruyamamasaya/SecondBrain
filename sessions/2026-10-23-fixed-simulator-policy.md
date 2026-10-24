# このMacのSimulator統一方針

- Project Context: MATCH（SecondBrainのiOS開発運用）。Git rootを確認し、既存指示を維持して更新。
- `AGENTS.md`へiPhone 17e／iOS 26.5／UDID `EB3A49ED-6553-4D7E-B933-387951643EAB`固定、ビルド・起動・テストでの明示指定、並列無効、代替端末・ランタイムの自動作成／更新禁止、未検出・互換性問題時の報告を追記。
- 接続済みiPhone 12 mini・iPhone 13・iPhone 17eの実機利用、既存アプリ・テストデータの初期化／削除禁止を明記。
- `TESTING.md`、`OPERATIONS.md`、`MAC_VALIDATION.md`の現行手順を整合。過去のsessions記録は維持。
- 文書のみの変更。`git diff --check`で検証。ビルド・起動・テスト、端末の作成・削除は未実施（作成0・削除0）。端末の存在・互換性とXCTestDevices残容量は今回未確認。
