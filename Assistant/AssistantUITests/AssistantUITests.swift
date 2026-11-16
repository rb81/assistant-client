import XCTest

/// Native launch smoke test performs no server connection.
final class AssistantUITests: XCTestCase {
    /// Connected screens and a synthetic write can be exercised without touching server data.
    @MainActor
    func testConnectedWorkspace() {
        verifyWorkspace(dark: false)
    }

    /// Dark appearance uses a per-window override and the same controls, not system-wide changes.
    @MainActor
    func testConnectedWorkspaceDark() {
        verifyWorkspace(dark: true)
    }

    /// External emails, tidy JSON and playable attachments share one light-mode transcript.
    @MainActor
    func testChatDetailsAndAudioAttachment() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--ui-chat-details"]
        app.launch()
        let thread = app.buttons["chat-thread-7"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        thread.click()
        XCTAssertTrue(app.staticTexts["Sent externally"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["To: guest@example.com"].exists)
        XCTAssertTrue(jsonField("delivery_status", in: app).exists)
        XCTAssertFalse(app.staticTexts["Install JetBrains Mono Nerd Font for terminal glyphs. Using the system monospace font."].exists)
        app.buttons["Load audio"].click()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.sliders["Playback position"].exists)
        XCTAssertTrue(app.buttons["Download"].exists)
        capture(app, name: "Chat attachment and external email light")
        app.staticTexts["task_complete"].click()
        let completion = jsonField("response", in: app)
        XCTAssertTrue(completion.waitForExistence(timeout: 5))
        let source = completion.value as? String ?? completion.label
        XCTAssertFalse(source.contains("\"input\""))
        XCTAssertFalse(source.contains("\"result\""))
        app.staticTexts["calendar_lookup"].click()
        XCTAssertTrue(jsonField("error", in: app).exists)
        XCTAssertFalse(app.staticTexts["Error"].exists)
        capture(app, name: "Tool detail JSON light")
        app.terminate()
    }

    /// A growing tool run must remain visible even when the message count never changes.
    @MainActor
    func testLiveToolsFollowAndRunningChatAllowsNewChat() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--ui-live-chat"]
        app.launch()
        let thread = app.buttons["chat-thread-7"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        thread.click()
        let latest = app.staticTexts["live_tool_3"]
        XCTAssertTrue(latest.waitForExistence(timeout: 20))
        XCTAssertTrue(latest.isHittable, "New tool calls should stay inside the visible transcript")
        capture(app, name: "Live tool following light")
        app.buttons["New chat"].click()
        XCTAssertTrue(app.staticTexts["What shall we work on?"].waitForExistence(timeout: 5))
        thread.click()
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertTrue(latest.isHittable, "Returning to a running conversation restores its latest activity")
        app.terminate()
    }

    /// Relaunch with all API reads failing proves the cache is on disk, not just shared model memory.
    @MainActor
    func testConversationCacheSurvivesRelaunchAndSettingsClear() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--ui-chat-details"]
        app.launch()
        let thread = app.buttons["chat-thread-7"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        thread.click()
        XCTAssertTrue(app.staticTexts["Sent externally"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--ui-fixture", "--ui-restore-cache"]
        app.launch()
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        thread.click()
        XCTAssertTrue(app.staticTexts["Sent externally"].waitForExistence(timeout: 10))
        XCTAssertTrue(jsonField("delivery_status", in: app).exists)
        app.typeKey(",", modifierFlags: .command)
        let clear = app.buttons["Clear conversation cache…"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.click()
        app.buttons["Clear local cache"].click()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Your conversations will appear here."].waitForExistence(timeout: 10))
        XCTAssertFalse(thread.exists)
        app.terminate()
    }

    @MainActor
    private func jsonField(_ key: String, in app: XCUIApplication) -> XCUIElement {
        let needle = "\"\(key)\""
        return app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", needle, needle)).firstMatch
    }

    @MainActor
    private func verifyWorkspace(dark: Bool) {
        let app = XCUIApplication()
        app.launchArguments = dark ? ["--ui-fixture", "--ui-dark"] : ["--ui-fixture"]
        app.launch()
        let thread = app.buttons["chat-thread-7"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        thread.click()
        XCTAssertTrue(app.buttons["Copy code"].waitForExistence(timeout: 10))
        app.buttons["Copy code"].click()
        XCTAssertTrue(app.buttons["Copied"].exists)
        XCTAssertTrue(app.staticTexts["workspace_search"].exists, "Tool calls render inline in the transcript")
        capture(app, name: dark ? "Chat dark" : "Chat light")
        let composer = app.textViews["Message Assistant"]
        composer.click()
        composer.typeText("What comes next?")
        app.buttons["Send"].click()
        XCTAssertTrue(app.staticTexts["Your follow-up was received."].waitForExistence(timeout: 10))
        app.staticTexts["Server Health"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Task worker"].waitForExistence(timeout: 5))
        capture(app, name: dark ? "Server Health dark" : "Server Health light")
        app.staticTexts["Data"].firstMatch.click()
        XCTAssertTrue(app.buttons["Upload file"].waitForExistence(timeout: 5))
        capture(app, name: dark ? "Data dark" : "Data light")
        app.staticTexts["Settings"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Assistant name"].waitForExistence(timeout: 5))
        capture(app, name: dark ? "Settings dark" : "Settings light")
        let nameField = app.textFields["Assistant name"]
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("Updated")
        XCTAssertEqual(nameField.value as? String, "Updated")
        XCTAssertTrue(app.buttons["Review changes"].isEnabled)
        app.buttons["Review changes"].click()
        let reviewed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: app.buttons["Save"])
        guard XCTWaiter.wait(for: [reviewed], timeout: 5) == .completed else {
            XCTFail("Review did not enable saving.")
            app.terminate()
            return
        }
        app.buttons["Save"].click()
        XCTAssertTrue(app.buttons["Save configuration"].waitForExistence(timeout: 5))
        app.buttons["Save configuration"].click()
        XCTAssertTrue(app.staticTexts["Saved. Activate these changes from Server Health when you are ready."].waitForExistence(timeout: 10))
        XCTAssertEqual(nameField.value as? String, "Updated")
        app.buttons["Agent.yaml"].click()
        XCTAssertTrue(app.textViews["Agent.yaml source"].waitForExistence(timeout: 5))
        app.staticTexts["Chats"].firstMatch.click()
        app.buttons["Delete selected chat task data"].click()
        XCTAssertTrue(app.buttons["Delete task data"].waitForExistence(timeout: 5))
        app.buttons["Delete task data"].click()
        XCTAssertTrue(app.staticTexts["Deleted task. Conversation and shared data are preserved. This chat is read-only."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textViews["Message Assistant"].isEnabled)
        app.terminate()
    }

    /// Keep synthetic screenshots in the test result bundle, never in the repository.
    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Launch must render and respond to input, not merely create a process.
    @MainActor
    func testDisconnectedLaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["connect-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your platform. One connection."].exists)
        app.buttons["connect-button"].click()
        let connectionSheet = app.sheets.firstMatch
        XCTAssertTrue(connectionSheet.waitForExistence(timeout: 5))
        connectionSheet.buttons["Cancel"].click()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: connectionSheet
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        app.typeKey(",", modifierFlags: .command)
        let menuBarToggle = app.checkBoxes["Keep a menu-bar item while Assistant is running"]
        XCTAssertTrue(menuBarToggle.waitForExistence(timeout: 5))
        menuBarToggle.click()
        menuBarToggle.click()
        app.terminate()
    }
}
