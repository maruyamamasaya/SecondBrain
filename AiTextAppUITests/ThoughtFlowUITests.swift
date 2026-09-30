import XCTest

final class ThoughtFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
    }

    func testPostCancelDeleteThenConfirmDelete() {
        let composer = openComposer()
        let post = app.buttons["postButton"]
        let body = "UIテスト Thought 🚀"

        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(post.isEnabled, "空文字では投稿できない")
        composer.tap()
        composer.typeText(body)
        XCTAssertTrue(post.waitForExistence(timeout: 2))
        XCTAssertTrue(post.isEnabled)
        post.tap()

        XCTAssertFalse(composer.exists, "投稿後に投稿画面を閉じる")
        let postedThought = app.staticTexts[body]
        XCTAssertTrue(postedThought.waitForExistence(timeout: 2), "投稿がTimeline先頭に表示される")

        openThoughtMenuAndChooseDelete()
        let cancel = app.buttons["cancelDeleteButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2))
        cancel.tap()
        XCTAssertTrue(postedThought.exists, "キャンセル時はThoughtが残る")

        openThoughtMenuAndChooseDelete()
        let confirm = app.buttons["confirmDeleteButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.tap()
        XCTAssertFalse(postedThought.waitForExistence(timeout: 1), "削除確定後はTimelineから消える")
    }

    func testThoughtBodyCopyActionIsAvailableFromTimelineMenu() {
        let composer = openComposer()
        let body = "コピーするThought"
        composer.tap()
        composer.typeText(body)
        app.buttons["postButton"].tap()

        XCTAssertTrue(app.staticTexts[body].waitForExistence(timeout: 2))
        let menu = app.buttons.matching(identifier: "thoughtMenu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        menu.tap()

        let copy = app.buttons["本文をコピー"]
        XCTAssertTrue(copy.waitForExistence(timeout: 2))
        copy.tap()
        XCTAssertFalse(copy.exists, "コピー後に操作メニューを閉じる")
    }

    func testMentionSuggestionsAppearBelowComposerAndInsertSelection() {
        let composer = openComposer()
        composer.typeText("@")

        let suggestion = app.buttons["mentionSuggestion_mio"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 2))
        XCTAssertGreaterThanOrEqual(
            suggestion.frame.minY,
            composer.frame.maxY,
            "メンション候補は入力欄の下に表示する"
        )

        suggestion.tap()
        XCTAssertTrue((composer.value as? String)?.contains("@mio ") == true)
        XCTAssertFalse(suggestion.exists)
    }

    func testMentionMenuSelectionInsertsHandleIntoEmptyComposer() {
        let composer = openComposer()
        app.buttons["mentionPersonaMenu"].tap()

        let mioMenuItem = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "@mio")).firstMatch
        XCTAssertTrue(mioMenuItem.waitForExistence(timeout: 2))
        mioMenuItem.tap()

        XCTAssertTrue((composer.value as? String)?.contains("@mio ") == true, "AI Personaの選択をThought本文に反映する")
    }

    func testActorIconOpensReadOnlyProfileAndPostDetail() {
        let composer = openComposer()
        let body = "プロフィールから開くThought"
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText(body)
        app.buttons["postButton"].tap()

        let actorIcon = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "actorIcon_")
        ).firstMatch
        XCTAssertTrue(actorIcon.waitForExistence(timeout: 2))
        actorIcon.tap()

        XCTAssertTrue(app.navigationBars["プロフィール"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["表示名"].exists)
        XCTAssertTrue(app.staticTexts["@myself"].exists)
        XCTAssertFalse(app.staticTexts["Posts / 過去の発言"].exists)
        app.navigationBars["プロフィール"].buttons.element(boundBy: 0).tap()
        app.staticTexts[body].tap()
        XCTAssertTrue(app.navigationBars["Thought"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["detailActorProfileLink"].exists)
    }

    func testCreateContinuationAndShowItInHistoryAndTimeline() {
        let composer = openComposer()
        let parent = "History A"
        let child = "History B"
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText(parent)
        app.buttons["postButton"].tap()

        let parentText = app.staticTexts[parent]
        XCTAssertTrue(parentText.waitForExistence(timeout: 2))
        parentText.tap()
        let writeContinuation = app.buttons["writeContinuationButton"]
        XCTAssertTrue(writeContinuation.waitForExistence(timeout: 2))
        writeContinuation.tap()

        let continuationComposer = app.textViews["continuationComposer"]
        XCTAssertTrue(continuationComposer.waitForExistence(timeout: 2))
        continuationComposer.tap()
        continuationComposer.typeText(child)
        app.buttons["postContinuationButton"].tap()

        XCTAssertTrue(app.staticTexts[parent].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts[child].waitForExistence(timeout: 2))
        app.navigationBars["Thought"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts[child].waitForExistence(timeout: 2), "Continuationが通常Timelineにも表示される")
    }

    func testWriteReplyOpensFocusedComposerAndPostsReply() {
        let composer = openComposer()
        let parent = "返信先Thought"
        let reply = "返信したThought"
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText(parent)
        app.buttons["postButton"].tap()

        app.staticTexts[parent].tap()
        let writeReply = app.buttons["writeReplyButton"]
        XCTAssertTrue(writeReply.waitForExistence(timeout: 2))
        writeReply.tap()

        let replyComposer = app.textViews["humanReplyComposer"]
        XCTAssertTrue(replyComposer.waitForExistence(timeout: 2))
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 2), "返信入力欄へfocusする")
        replyComposer.typeText(reply)
        let postReply = app.buttons["postHumanReplyButton"]
        XCTAssertTrue(postReply.isEnabled)
        postReply.tap()

        XCTAssertTrue(app.navigationBars["Thoughts"].waitForExistence(timeout: 2), "返信後はTimelineへ戻る")
        XCTAssertTrue(app.staticTexts[reply].waitForExistence(timeout: 2))
        XCTAssertFalse(replyComposer.exists)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "replyContext_"))
                .firstMatch
                .waitForExistence(timeout: 2),
            "Timelineの返信に返信先本文を表示する"
        )
    }

    func testMentionedAIAutoRepliesAndNormalReplyContinuesLatestLeaf() {
        let composer = openComposer()
        let root = "@mio このUIどう思う？"
        composer.tap()
        composer.typeText(root)
        app.buttons["postButton"].tap()

        XCTAssertTrue(app.staticTexts[root].waitForExistence(timeout: 3), "Human ThoughtはAI通信を待たず表示する")
        XCTAssertTrue(app.staticTexts["一緒に考えてみましょう。"].waitForExistence(timeout: 5), "@mioでAI Thoughtを自動生成する")

        let rootRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "timelineThought_", root)).firstMatch
        XCTAssertTrue(rootRow.waitForExistence(timeout: 2))
        rootRow.tap()
        XCTAssertTrue(app.staticTexts["会話"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["一緒に考えてみましょう。"].exists, "AI返信を別枠ではなくConversationへ表示する")
        app.buttons["writeReplyButton"].tap()
        let replyComposer = app.textViews["humanReplyComposer"]
        XCTAssertTrue(replyComposer.waitForExistence(timeout: 2))
        replyComposer.typeText("もう少し詳しく")
        app.buttons["postHumanReplyButton"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "replyContext_")).firstMatch.waitForExistence(timeout: 2),
            "通常返信は会話の最新AI Thoughtを返信先にする"
        )
    }

    func testHomeHidesRepliesAfterTheFirstByDefaultAndCanShowThem() {
        app.terminate()
        app.launchArguments.append("--ui-testing-reply-collapse")
        app.launch()

        let firstReplyRow = timelineRow(containing: "最初の返信")
        let laterReplyRow = timelineRow(containing: "2件目の返信")
        XCTAssertTrue(firstReplyRow.waitForExistence(timeout: 5))
        XCTAssertTrue(laterReplyRow.waitForNonExistence(timeout: 2), "2件目以降の返信はデフォルトで隠す")

        let replyVisibilityButton = app.buttons["homeReplyVisibilityButton"]
        XCTAssertTrue(replyVisibilityButton.exists)
        replyVisibilityButton.tap()
        XCTAssertTrue(firstReplyRow.exists, "最初の返信は表示する")
        XCTAssertTrue(laterReplyRow.waitForExistence(timeout: 2), "押すとすべての返信を表示する")

        replyVisibilityButton.tap()
        XCTAssertTrue(laterReplyRow.waitForNonExistence(timeout: 2), "再度押すと2件目以降の返信を隠す")
    }

    func testTimelineOpensLocalAnalyticsAndShowsSummary() {
        let composer = openComposer()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("分析対象Thought")
        app.buttons["postButton"].tap()

        app.buttons["homeInsightsButton"].tap()
        let analyticsButton = app.buttons["insightsAnalyticsButton"]
        XCTAssertTrue(analyticsButton.waitForExistence(timeout: 2))
        analyticsButton.tap()

        XCTAssertTrue(app.navigationBars["ローカル分析"].waitForExistence(timeout: 2))
        let elements = app.descendants(matching: .any)
        XCTAssertEqual(elements["analyticsTodayCount"].label, "今日、1件")
        XCTAssertEqual(elements["analyticsSevenDayCount"].label, "過去7日、1件")
        XCTAssertEqual(elements["analyticsThirtyDayCount"].label, "過去30日、1件")
        XCTAssertEqual(elements["analyticsActiveDayCount"].label, "過去30日の活動日、1日")
        XCTAssertEqual(elements["analyticsAveragePerActiveDay"].label, "1活動日あたり平均、1.0件")
        XCTAssertTrue(elements["analyticsDailyCellToday"].exists)
        XCTAssertTrue(elements["analyticsDailyCellToday"].label.hasSuffix("、1件"))
    }

    func testSearchOpensResultAndNavigatesToThoughtDetail() {
        for body in ["検索対象のThought", "別のメモ"] {
            let composer = openComposer()
            composer.tap()
            composer.typeText(body)
            app.buttons["postButton"].tap()
        }

        XCTAssertTrue(app.navigationBars["思考メモ"].waitForExistence(timeout: 2))

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.tap()
        searchField.typeText("検索対象")

        let results = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "timelineThought_")
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(app.staticTexts["検索対象のThought"].exists)
        XCTAssertFalse(app.staticTexts["別のメモ"].exists)
        results.element(boundBy: 0).tap()

        XCTAssertTrue(app.navigationBars["Thought"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["writeContinuationButton"].waitForExistence(timeout: 2))
    }

    func testFiveTabsMentionsProfileAndSettingsNavigation() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        for title in ["ホーム", "メンション", "AI機能", "ツール", "プロフィール"] {
            XCTAssertTrue(tabBar.buttons[title].exists, "\(title)タブを表示する")
        }

        tabBar.buttons["AI機能"].tap()
        XCTAssertTrue(app.navigationBars["AI機能"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["aiPersonasButton"].exists)
        XCTAssertTrue(app.buttons["aiUsageAnalyticsButton"].exists)
        XCTAssertTrue(app.buttons["externalBrainSettingsButton"].exists)
        app.buttons["aiProviderSettingsButton"].tap()
        XCTAssertTrue(app.navigationBars["AIプロバイダー設定"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["geminiProviderSettingsButton"].exists)
        XCTAssertTrue(app.buttons["openAIProviderSettingsButton"].exists)
        XCTAssertTrue(app.buttons["claudeProviderSettingsButton"].exists)
        app.navigationBars["AIプロバイダー設定"].buttons.firstMatch.tap()
        tabBar.buttons["ホーム"].tap()

        let composer = openComposer()
        composer.tap()
        composer.typeText("@myself メンション確認")
        app.buttons["postButton"].tap()

        app.staticTexts["@myself メンション確認"].tap()
        XCTAssertTrue(app.navigationBars["Thought"].waitForExistence(timeout: 2))
        app.buttons["writeReplyButton"].tap()
        let replyComposer = app.textViews["humanReplyComposer"]
        XCTAssertTrue(replyComposer.waitForExistence(timeout: 2))
        replyComposer.typeText("リプライ確認")
        app.buttons["postHumanReplyButton"].tap()

        tabBar.buttons["メンション"].tap()
        XCTAssertTrue(app.navigationBars["メンション"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.segmentedControls["mentionsKindPicker"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.segmentedControls["mentionsKindPicker"].buttons["メンション"].isSelected)
        XCTAssertTrue(app.staticTexts["@myself メンション確認"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["リプライ確認"].exists)
        app.segmentedControls["mentionsKindPicker"].buttons["リプライ"].tap()
        XCTAssertTrue(app.staticTexts["リプライ確認"].waitForExistence(timeout: 2))

        tabBar.buttons["ツール"].tap()
        XCTAssertTrue(app.navigationBars["ツール"].waitForExistence(timeout: 2))
        for title in ["Shared Memo", "My Wiki", "Study", "Study App", "Tool"] {
            XCTAssertTrue(app.buttons[title].exists, "\(title)タイルを表示する")
        }

        tabBar.buttons["ホーム"].tap()
        app.buttons["homeInsightsButton"].tap()
        XCTAssertTrue(app.navigationBars["振り返り"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["insightsSummaryLibraryButton"].exists)
        XCTAssertTrue(app.buttons["insightsJournalButton"].exists)
        XCTAssertTrue(app.buttons["insightsDailySummaryButton"].exists)
        XCTAssertTrue(app.buttons["insightsAnalyticsButton"].exists)
        app.buttons["insightsSummaryLibraryButton"].tap()
        XCTAssertTrue(app.navigationBars["サマリー"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["まだサマリーはありません"].exists)
        app.navigationBars["サマリー"].buttons.element(boundBy: 0).tap()

        tabBar.buttons["プロフィール"].tap()
        XCTAssertTrue(app.navigationBars["プロフィール"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["表示名"].exists)
        XCTAssertTrue(app.staticTexts["@myself"].exists)
        XCTAssertFalse(app.staticTexts["Posts / 過去の発言"].exists)
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 2))
    }

    func testHomeDraftSurvivesTabSwitch() {
        let composer = openComposer()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("タブを移動しても残るDraft")
        app.buttons["キャンセル"].tap()

        app.tabBars.buttons["プロフィール"].tap()
        XCTAssertTrue(app.navigationBars["プロフィール"].waitForExistence(timeout: 2))
        app.tabBars.buttons["ホーム"].tap()

        app.buttons["openComposerButton"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        XCTAssertEqual(composer.value as? String, "タブを移動しても残るDraft")
    }

    func testFourThemesAcrossFiveTabsAndPersistence() {
        app.terminate()
        app.launchArguments.append("--ui-testing-theme-persistence")
        app.launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))

        for theme in ["default", "dynamicAurora", "pulseNeon", "blueCosmos"] {
            tabBar.buttons["プロフィール"].tap()
            XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 2))
            app.buttons["settingsButton"].tap()
            app.buttons["appearanceThemeButton"].tap()

            let option = app.buttons["themeOption_\(theme)"]
            XCTAssertTrue(option.waitForExistence(timeout: 2))
            option.tap()
            XCTAssertEqual(option.value as? String, "選択中")
            add(XCTAttachment(screenshot: app.screenshot(), quality: .medium).named("Theme-\(theme)-Appearance"))

            app.navigationBars["外観とテーマ"].buttons.element(boundBy: 0).tap()
            app.navigationBars["設定"].buttons["完了"].tap()

            for tab in ["ホーム", "メンション", "AI機能", "ツール", "プロフィール"] {
                tabBar.buttons[tab].tap()
                XCTAssertTrue(tabBar.buttons[tab].isSelected)
                add(XCTAttachment(screenshot: app.screenshot(), quality: .medium).named("Theme-\(theme)-\(tab)"))
            }
        }

        app.terminate()
        app.launch()
        app.tabBars.buttons["プロフィール"].tap()
        app.buttons["settingsButton"].tap()
        app.buttons["appearanceThemeButton"].tap()
        XCTAssertEqual(app.buttons["themeOption_blueCosmos"].value as? String, "選択中")
    }

    func testAddsTagShowsItOnTimelineAndOpensTaggedThoughtDetail() {
        let body = "タグUIフロー"
        let tagName = "仕事"
        let composer = openComposer()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText(body)
        app.buttons["postButton"].tap()

        app.staticTexts[body].tap()
        XCTAssertTrue(app.buttons["editThoughtTagsButton"].waitForExistence(timeout: 2))
        app.buttons["editThoughtTagsButton"].tap()
        let tagField = app.textFields["newThoughtTagField"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 2))
        tagField.tap()
        tagField.typeText(tagName)
        app.buttons["addThoughtTagButton"].tap()
        XCTAssertTrue(app.staticTexts[tagName].waitForExistence(timeout: 2))
        app.buttons["closeThoughtTagEditor"].tap()

        app.navigationBars["Thought"].buttons.element(boundBy: 0).tap()
        let tagButton = app.buttons.matching(NSPredicate(format: "label == %@", "タグ \(tagName)")).firstMatch
        XCTAssertTrue(tagButton.waitForExistence(timeout: 2), "Timelineにタグが表示される")
        tagButton.tap()

        XCTAssertTrue(app.navigationBars[tagName].waitForExistence(timeout: 2))
        let taggedThought = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "taggedThought_")
        ).firstMatch
        XCTAssertTrue(taggedThought.waitForExistence(timeout: 2))
        taggedThought.tap()
        XCTAssertTrue(app.navigationBars["Thought"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts[body].exists)
    }

    private func openThoughtMenuAndChooseDelete() {
        let menu = app.buttons.matching(identifier: "thoughtMenu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        menu.tap()
        let delete = app.buttons["削除"]
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        delete.tap()
    }

    private func openComposer() -> XCUIElement {
        let button = app.buttons["openComposerButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        let composer = app.textViews["thoughtComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        return composer
    }

    private func timelineRow(containing body: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "timelineThought_", body)
        ).firstMatch
    }
}

private extension XCTAttachment {
    func named(_ name: String) -> XCTAttachment {
        self.name = name
        lifetime = .keepAlways
        return self
    }
}
