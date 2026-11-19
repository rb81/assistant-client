import XCTest

/// Native launch smoke test performs no server connection.
final class AssistantUITests: XCTestCase {
    /// Locked guidance is readable, but edits open a separate preference draft.
    @MainActor
    func testLockedSkillIsReadableAndCanStartPreferenceDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture"]
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons["nav-configuration"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.click()
        let skills = app.buttons["settings-section-assistant-skills"]
        XCTAssertTrue(skills.waitForExistence(timeout: 10))
        skills.click()
        let email = app.buttons["skill-EMAIL"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.click()
        XCTAssertTrue(app.staticTexts["Verify the recipient before composing the message."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Edit skill"].exists)
        app.buttons["Add preferences"].click()
        XCTAssertTrue(app.textFields["Skill ID"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Skill ID"].value as? String, "EMAIL.PREFERENCES")
    }

    /// Settings keep one navigation column while lazy reads and saving preserve the draft.
    @MainActor
    func testSettingsPanesPreserveDraftsAndLayout() {
        verifySettingsPanes(dark: false)
    }

    /// Dark appearance keeps the same pane geometry and readable selected destinations.
    @MainActor
    func testSettingsPanesDark() {
        verifySettingsPanes(dark: true)
    }

    @MainActor
    private func verifySettingsPanes(dark: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--ui-slow-reads"] + (dark ? ["--ui-dark"] : [])
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons["nav-configuration"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.click()
        let name = app.textFields["Assistant name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        let detail = app.scrollViews["settings-detail"]
        let detailBefore = detail.frame
        let reviewBefore = app.buttons["Review changes"].frame
        capture(app, name: dark ? "Settings panes loading dark" : "Settings panes loading light")
        waitUntilEnabled(name)
        XCTAssertEqual(detail.frame.minY, detailBefore.minY, accuracy: 1)
        XCTAssertEqual(detail.frame.height, detailBefore.height, accuracy: 1)
        XCTAssertEqual(app.buttons["Review changes"].frame.minY, reviewBefore.minY, accuracy: 1)
        let nav = app.scrollViews["settings-navigation"]
        let identity = app.buttons["settings-section-assistant-identity"]
        let instructionsButton = app.buttons["settings-section-assistant-instructions"]
        let limits = app.buttons["settings-section-advanced-advanced:Task limits"]
        let search = app.textFields["Find a setting"]
        let identityFrame = identity.frame
        let instructionsFrame = instructionsButton.frame
        XCTAssertLessThan(nav.frame.minY, search.frame.minY)
        XCTAssertLessThan(nav.frame.maxX, search.frame.minX)
        XCTAssertLessThan(identity.frame.maxX, name.frame.minX)
        XCTAssertFalse(app.buttons["settings-category-assistant"].exists)
        XCTAssertTrue(limits.exists)
        XCTAssertTrue(app.textFields["Timezone"].exists)
        XCTAssertFalse(app.textFields["Approval email"].exists)
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Pane draft")
        XCTAssertEqual(name.value as? String, "Pane draft")
        limits.click()
        let iterations = app.textFields["Maximum iterations"]
        XCTAssertTrue(iterations.waitForExistence(timeout: 5))
        waitUntilEnabled(iterations)
        XCTAssertEqual(identity.frame, identityFrame)
        XCTAssertEqual(instructionsButton.frame, instructionsFrame)
        XCTAssertTrue(instructionsButton.isHittable)
        app.buttons["settings-section-connections-email"].click()
        let imap = app.textFields["IMAP server"]
        XCTAssertTrue(imap.waitForExistence(timeout: 5))
        waitUntilEnabled(imap)
        app.buttons["settings-section-connections-calendar"].click()
        XCTAssertTrue(app.staticTexts["Default provider"].waitForExistence(timeout: 5))
        app.buttons["settings-section-safety-approvals"].click()
        let approvalEmail = app.textFields["Approval email"]
        XCTAssertTrue(approvalEmail.waitForExistence(timeout: 5))
        waitUntilEnabled(approvalEmail)
        XCTAssertTrue(app.staticTexts["Approval delivery"].exists)
        limits.click()
        XCTAssertTrue(iterations.waitForExistence(timeout: 5))
        identity.click()
        XCTAssertEqual(name.value as? String, "Pane draft", "Switching panes must preserve unsaved edits")
        instructionsButton.click()
        let instructions = app.textViews["Assistant instructions"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        let instructionsReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Be thoughtful, clear, and useful."), object: instructions)
        XCTAssertEqual(XCTWaiter.wait(for: [instructionsReady], timeout: 10), .completed)
        instructions.click()
        instructions.typeKey("a", modifierFlags: .command)
        instructions.typeText("Pane instructions draft")
        XCTAssertEqual(instructions.value as? String, "Pane instructions draft")
        identity.click()
        app.buttons["Review changes"].click()
        waitUntilEnabled(app.buttons["Save changes"])
        app.buttons["Save changes"].click()
        let confirm = app.buttons["Save configuration"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        let feedback = app.buttons["settings-feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 10))
        XCTAssertTrue(feedback.label.hasPrefix("Saved."), feedback.label)
        waitUntilEnabled(name)
        XCTAssertEqual(name.value as? String, "Pane draft")
        XCTAssertEqual(app.buttons["Review changes"].frame.minY, reviewBefore.minY, accuracy: 1)
        capture(app, name: dark ? "Settings panes saved dark" : "Settings panes saved light")
        instructionsButton.click()
        let savedInstructions = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Pane instructions draft"), object: instructions)
        XCTAssertEqual(XCTWaiter.wait(for: [savedInstructions], timeout: 10), .completed)
        app.buttons["settings-section-app-app"].click()
        XCTAssertTrue(app.staticTexts["Notifications"].waitForExistence(timeout: 5))
        limits.click()
        XCTAssertTrue(iterations.waitForExistence(timeout: 5))
        search.click()
        search.typeText("IMAP server")
        let destination = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Connections › Email")).firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        destination.click()
        XCTAssertTrue(app.textFields["IMAP server"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed,
                       "Control did not become enabled: \(element.identifier)", file: file, line: line)
    }

    /// Slow reads must not replace the file viewport or insert a row above log content.
    @MainActor
    func testLoadingKeepsWorkspaceAndLogGeometry() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--ui-slow-reads"]
        app.launch()
        defer { app.terminate() }
        let data = app.buttons["nav-data"]
        app.buttons["nav-connection"].click()
        XCTAssertTrue(data.waitForExistence(timeout: 10))
        data.click()
        let folder = app.textFields["New folder name"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        let folderBefore = folder.frame
        let dangerBefore = app.buttons["Reset data…"].frame
        capture(app, name: "Workspace during read")
        XCTAssertTrue(app.buttons["notes"].waitForExistence(timeout: 10))
        XCTAssertEqual(folder.frame.minY, folderBefore.minY, accuracy: 1)
        XCTAssertEqual(app.buttons["Reset data…"].frame.minY, dangerBefore.minY, accuracy: 1)
        XCTAssertFalse(app.staticTexts["Loading workspace…"].exists)
        capture(app, name: "Workspace after read")
        openSupport(app)
        let logs = app.buttons["View logs"]
        XCTAssertTrue(logs.waitForExistence(timeout: 10))
        logs.click()
        let output = app.scrollViews["inspector-output"]
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        let logBefore = output.frame
        XCTAssertTrue(jsonField("message", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(output.frame.minY, logBefore.minY, accuracy: 1)
        XCTAssertEqual(output.frame.height, logBefore.height, accuracy: 1)
    }

    /// Saved key state and log JSON stay readable in both supported appearances.
    @MainActor
    func testCredentialStatusAndReadableLogs() {
        for dark in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = dark ? ["--ui-fixture", "--ui-dark"] : ["--ui-fixture"]
            app.launch()
            openSupport(app)
            let logs = app.buttons["View logs"]
            XCTAssertTrue(logs.waitForExistence(timeout: 10))
            logs.click()
            let message = jsonField("message", in: app)
            XCTAssertTrue(message.waitForExistence(timeout: 10))
            XCTAssertFalse((message.value as? String ?? message.label).contains("\\\""))
            capture(app, name: dark ? "Readable logs dark" : "Readable logs light")
            app.buttons["Done"].click()
            app.buttons["nav-configuration"].click()
            let models = app.buttons["settings-section-models-models"]
            XCTAssertTrue(models.waitForExistence(timeout: 10))
            models.click()
            XCTAssertTrue(app.staticTexts["Saved and active"].waitForExistence(timeout: 10))
            capture(app, name: dark ? "Saved key status dark" : "Saved key status light")
            app.terminate()
        }
    }

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
        app.launchArguments = ["--ui-fixture", "--ui-chat-details", "-chats.showToolCalls", "YES"]
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
        app.launchArguments = ["--ui-fixture", "--ui-live-chat", "-chats.showToolCalls", "YES"]
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
        app.launchArguments = ["--ui-fixture", "-chats.showToolCalls", "YES"] + (dark ? ["--ui-dark"] : [])
        app.launch()
        let thread = app.buttons["chat-thread-7"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        thread.click()
        XCTAssertTrue(app.buttons["Copy code"].waitForExistence(timeout: 10))
        app.buttons["Copy code"].click()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["workspace_search"].exists, "Tool calls render inline in the transcript")
        capture(app, name: dark ? "Chat dark" : "Chat light")
        let composer = app.textViews["Message Assistant"]
        composer.click()
        composer.typeText("What comes next?")
        XCTAssertEqual(composer.value as? String, "What comes next?")
        XCTAssertTrue(app.buttons["Send"].isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(app.buttons["Send"].frame))
        XCTAssertTrue(app.buttons["Send"].isEnabled)
        app.buttons["Send"].click()
        let response = app.staticTexts.matching(NSPredicate(
            format: "value == %@ OR label == %@", "Your follow-up was received.", "Your follow-up was received."
        )).firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 10))
        openSupport(app)
        XCTAssertTrue(app.staticTexts["Task worker"].waitForExistence(timeout: 5))
        capture(app, name: dark ? "Server Health dark" : "Server Health light")
        app.buttons["nav-connection"].click()
        app.buttons["nav-data"].click()
        XCTAssertTrue(app.buttons["Upload file"].waitForExistence(timeout: 5))
        capture(app, name: dark ? "Data dark" : "Data light")
        app.buttons["nav-configuration"].click()
        XCTAssertTrue(app.staticTexts["Assistant name"].waitForExistence(timeout: 5))
        capture(app, name: dark ? "Settings dark" : "Settings light")
        let nameField = app.textFields["Assistant name"]
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("Updated")
        XCTAssertEqual(nameField.value as? String, "Updated")
        XCTAssertTrue(app.buttons["Review changes"].isEnabled)
        app.buttons["Review changes"].click()
        let reviewed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: app.buttons["Save changes"])
        guard XCTWaiter.wait(for: [reviewed], timeout: 5) == .completed else {
            XCTFail("Review did not enable saving.")
            app.terminate()
            return
        }
        app.buttons["Save changes"].click()
        XCTAssertTrue(app.buttons["Save configuration"].waitForExistence(timeout: 5))
        app.buttons["Save configuration"].click()
        let feedback = app.buttons["settings-feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 10))
        XCTAssertEqual(feedback.label, "Saved. Apply changes from Connection & Support when you are ready.")
        XCTAssertEqual(nameField.value as? String, "Updated")
        XCTAssertFalse(app.buttons["Agent.yaml"].exists)
        app.buttons["settings-section-app-app"].click()
        XCTAssertTrue(app.staticTexts["Notifications"].waitForExistence(timeout: 5))
        app.buttons["nav-inbox"].click()
        app.buttons["Delete selected chat task data"].click()
        XCTAssertTrue(app.buttons["Delete task data"].waitForExistence(timeout: 5))
        app.buttons["Delete task data"].click()
        XCTAssertTrue(app.staticTexts["Deleted task. Conversation and shared data are preserved. This chat is read-only."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textViews["Message Assistant"].isEnabled)
        app.terminate()
    }

    @MainActor
    private func openSupport(_ app: XCUIApplication) {
        app.buttons["nav-connection"].click()
        app.buttons["nav-services"].click()
    }

    /// Connection & Support identifies unconfirmed actions and shows service status without expansion.
    @MainActor
    func testSupportShowsUnconfirmedActionAndServices() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--ui-unconfirmed-action"]
        app.launch()
        defer { app.terminate() }
        openSupport(app)
        XCTAssertTrue(app.staticTexts["Send a chat reply"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No receipt from the server"].exists)
        XCTAssertTrue(app.staticTexts["Task worker"].waitForExistence(timeout: 5))
        app.buttons["Review operation history"].click()
        XCTAssertTrue(app.buttons["Refresh"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].exists)
    }

    /// Scheduled output has no normal reply composer; a follow-up is a separate, unsent chat.
    @MainActor
    func testReminderRunsStaySeparateAndOpenAnUnsentFollowUp() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["chat-thread-7"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["chat-thread-8"].exists)
        app.buttons["nav-reminders"].click()
        let reminder = app.buttons["chat-thread-8"]
        XCTAssertTrue(reminder.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["chat-thread-7"].exists)
        reminder.click()
        XCTAssertTrue(app.staticTexts["Scheduled run"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["There are no events tomorrow."].exists)
        XCTAssertFalse(app.textViews["Message Assistant"].exists)
        app.buttons["View schedule"].click()
        XCTAssertTrue(app.staticTexts["Delivery: Telegram"].waitForExistence(timeout: 5))
        app.buttons["Done"].click()
        app.buttons["Ask about this run"].click()
        let message = app.textViews["Message Assistant"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue((message.value as? String ?? "").contains("About scheduled run #8"))
        XCTAssertTrue(app.staticTexts["A fresh conversation"].exists)
        XCTAssertTrue(app.buttons["Send"].isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(app.buttons["Send"].frame))
    }

    /// Send remains available after typing a draft and reaches the fixture server.
    @MainActor
    func testChatComposerSendsFromInsideWindow() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture"]
        app.launch()
        defer { app.terminate() }
        let thread = app.buttons["chat-thread-7"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        thread.click()
        let composer = app.textViews["Message Assistant"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("What comes next?")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.isHittable && send.isEnabled)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(send.frame))
        send.click()
        XCTAssertTrue(app.staticTexts["Your follow-up was received."].waitForExistence(timeout: 10))
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
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
        let menuBarToggle = app.descendants(matching: .any).matching(identifier: "menu-bar-preference").firstMatch
        XCTAssertTrue(menuBarToggle.waitForExistence(timeout: 5))
        menuBarToggle.click()
        menuBarToggle.click()
        app.terminate()
    }
}
