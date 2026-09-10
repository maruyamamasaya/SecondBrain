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
        let composer = app.textViews["thoughtComposer"]
        let post = app.buttons["postButton"]
        let body = "UIテスト Thought 🚀"

        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(post.exists, "空文字では投稿ボタンを表示しない")
        composer.tap()
        composer.typeText(body)
        XCTAssertTrue(post.waitForExistence(timeout: 2))
        XCTAssertTrue(post.isEnabled)
        post.tap()

        XCTAssertEqual(composer.value as? String, "", "投稿後にComposerが空になる")
        XCTAssertFalse(post.exists, "投稿後は投稿ボタンを再び隠す")
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

    func testCreateContinuationAndShowItInHistoryAndTimeline() {
        let composer = app.textViews["thoughtComposer"]
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

    func testTimelineOpensLocalAnalyticsAndShowsSummary() {
        let composer = app.textViews["thoughtComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("分析対象Thought")
        app.buttons["postButton"].tap()

        let analyticsButton = app.buttons["thoughtAnalyticsButton"]
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

    func testQuickCapturePostsTrimmedThoughtOnceAndReturnsToTimeline() {
        let quickCapture = app.buttons["quickCaptureButton"]
        XCTAssertTrue(quickCapture.waitForExistence(timeout: 5))
        quickCapture.tap()

        XCTAssertTrue(app.navigationBars["Quick Capture"].waitForExistence(timeout: 2))
        let editor = app.textViews["quickCaptureEditor"]
        let post = app.buttons["quickCapturePostButton"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        XCTAssertEqual(editor.value as? String, "")
        XCTAssertFalse(post.isEnabled)
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 2), "表示時に入力へfocusする")

        editor.typeText("  Quick Capture Thought  ")
        XCTAssertTrue(post.isEnabled)
        post.tap()

        XCTAssertTrue(app.navigationBars["Thoughts"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Quick Capture Thought")).count, 1)
    }

    func testExternalQuickCaptureRouteFromColdLaunchPostsOnceAndReturnsToTimeline() throws {
        app.terminate()
        try openAppRoute(URL(string: "aitextapp://quick-capture")!)

        XCTAssertTrue(app.navigationBars["Quick Capture"].waitForExistence(timeout: 5))
        let editor = app.textViews["quickCaptureEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 2), "外部routeでも入力へfocusする")
        editor.typeText("Widget route Thought")
        app.buttons["quickCapturePostButton"].tap()

        XCTAssertTrue(app.navigationBars["Thoughts"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Widget route Thought")).count, 1)
        XCTAssertFalse(app.navigationBars["Quick Capture"].exists, "投稿後にrouteを消費してTimelineへ戻る")
    }

    func testExternalQuickCaptureRouteWhileForegroundCanBeDismissedAndConsumed() throws {
        XCTAssertTrue(app.navigationBars["Thoughts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Quick Capture"].exists, "通常起動ではQuick Captureを開かない")

        try openAppRoute(URL(string: "aitextapp://quick-capture")!)
        XCTAssertTrue(app.navigationBars["Quick Capture"].waitForExistence(timeout: 2))
        app.buttons["quickCaptureCancelButton"].tap()

        XCTAssertTrue(app.navigationBars["Thoughts"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.navigationBars["Quick Capture"].exists)
    }

    func testMalformedExternalRouteDoesNotOpenQuickCapture() throws {
        XCTAssertTrue(app.navigationBars["Thoughts"].waitForExistence(timeout: 5))

        try openAppRoute(URL(string: "aitextapp://quick-capture?body=should-not-be-accepted")!)

        XCTAssertTrue(app.navigationBars["Thoughts"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.navigationBars["Quick Capture"].exists)
    }

    func testQuickCaptureRejectsEmptyAndOverLimitDraft() {
        app.buttons["quickCaptureButton"].tap()
        let editor = app.textViews["quickCaptureEditor"]
        let post = app.buttons["quickCapturePostButton"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        editor.typeText("   ")
        XCTAssertFalse(post.isEnabled, "空白だけのThoughtは投稿できない")
        app.buttons["quickCaptureCancelButton"].tap()
        app.alerts["入力中のThoughtを破棄しますか？"].buttons["破棄"].tap()
        app.buttons["quickCaptureButton"].tap()
        let reopenedEditor = app.textViews["quickCaptureEditor"]
        let reopenedPost = app.buttons["quickCapturePostButton"]
        XCTAssertTrue(reopenedEditor.waitForExistence(timeout: 2))
        reopenedEditor.typeText(String(repeating: "あ", count: 141))
        XCTAssertEqual(app.staticTexts["quickCaptureCharacterCount"].label, "文字数 141、上限 140")
        XCTAssertFalse(reopenedPost.isEnabled, "141文字を超えるThoughtは投稿できない")
    }

    func testQuickCapturePostsExactly140Characters() {
        let body = String(repeating: "a", count: 140)
        app.buttons["quickCaptureButton"].tap()
        let editor = app.textViews["quickCaptureEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        editor.typeText(body)
        XCTAssertEqual(app.staticTexts["quickCaptureCharacterCount"].label, "文字数 140、上限 140")
        XCTAssertTrue(app.buttons["quickCapturePostButton"].isEnabled)
        app.buttons["quickCapturePostButton"].tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timelineThought_")).count, 1)
    }

    func testQuickCaptureConfirmsDiscardAndKeepsDraftWhenContinuing() {
        app.buttons["quickCaptureButton"].tap()
        let editor = app.textViews["quickCaptureEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        editor.typeText("破棄確認する入力")
        app.buttons["quickCaptureCancelButton"].tap()

        let alert = app.alerts["入力中のThoughtを破棄しますか？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        alert.buttons["続ける"].tap()
        XCTAssertEqual(editor.value as? String, "破棄確認する入力")

        app.buttons["quickCaptureCancelButton"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        alert.buttons["破棄"].tap()
        XCTAssertTrue(app.navigationBars["Thoughts"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["破棄確認する入力"].exists)
    }

    func testQuickCaptureCancelWithEmptyDraftClosesImmediately() {
        app.buttons["quickCaptureButton"].tap()
        XCTAssertTrue(app.navigationBars["Quick Capture"].waitForExistence(timeout: 2))
        app.buttons["quickCaptureCancelButton"].tap()
        XCTAssertTrue(app.navigationBars["Thoughts"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.alerts["入力中のThoughtを破棄しますか？"].exists)
    }

    func testQuickCaptureFailureKeepsDraftAndScreenOpen() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing-fail-posts"]
        app.launch()
        app.buttons["quickCaptureButton"].tap()
        let editor = app.textViews["quickCaptureEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        editor.typeText("失敗しても保持")
        app.buttons["quickCapturePostButton"].tap()

        let alert = app.alerts["投稿できませんでした"]
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        alert.buttons["OK"].tap()
        XCTAssertTrue(app.navigationBars["Quick Capture"].exists)
        XCTAssertEqual(editor.value as? String, "失敗しても保持")
    }

    func testSearchOpensResultAndNavigatesToThoughtDetail() {
        let composer = app.textViews["thoughtComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        for body in ["検索対象のThought", "別のメモ"] {
            composer.tap()
            composer.typeText(body)
            app.buttons["postButton"].tap()
        }

        app.buttons["thoughtSearchButton"].tap()
        XCTAssertTrue(app.navigationBars["Thought検索"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["thoughtSearchInitialState"].waitForExistence(timeout: 2))

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.tap()
        searchField.typeText("検索対象")

        let results = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "searchResult_")
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(app.staticTexts["検索対象のThought"].exists)
        XCTAssertFalse(app.staticTexts["別のメモ"].exists)
        results.element(boundBy: 0).tap()

        XCTAssertTrue(app.navigationBars["Thought"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["writeContinuationButton"].exists)
    }

    func testAddsTagShowsItOnTimelineAndOpensTaggedThoughtDetail() {
        let body = "タグUIフロー"
        let tagName = "仕事"
        let composer = app.textViews["thoughtComposer"]
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

    private func openAppRoute(_ url: URL) throws {
        guard #available(iOS 16.4, *) else {
            throw XCTSkip("XCUIApplication.open requires iOS 16.4 or newer")
        }
        app.open(url)
    }

    private func openThoughtMenuAndChooseDelete() {
        let menu = app.buttons.matching(identifier: "thoughtMenu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        menu.tap()
        let delete = app.buttons["削除"]
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        delete.tap()
    }
}
