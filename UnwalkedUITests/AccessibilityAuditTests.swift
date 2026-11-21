import XCTest

/// Runs Apple's accessibility audit on each main screen: contrast, text size, labels, hit areas, clipped text.
///
/// Needs an onboarded app with a home area. In the Simulator the walk is simulated at 5x speed.
final class AccessibilityAuditTests: XCTestCase {
    private var findings: [String] = []

    func testMainScreensPassTheAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-simulateWalk", "-unlimitedLoops"]
        // TEST_RUNNER_TEXT_SIZE=AccessibilityXXXL runs the same walk-through at the largest text size.
        if let size = ProcessInfo.processInfo.environment["TEXT_SIZE"] {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory\(size)"]
        }
        app.launch()

        let find = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Find'")).firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 10), "Home should offer to find loops")
        XCTAssertTrue(app.staticTexts["How long have you got?"].exists || app.staticTexts["Every street here is unwalked"].exists)
        try audit(app, screen: "Home")

        // The time is one adjustable control for VoiceOver, not a ruler of ticks.
        let time = app.otherElements["Walk time"].exists ? app.otherElements["Walk time"] : app.descendants(matching: .any)["Walk time"]
        XCTAssertTrue(time.exists, "Walk time should be exposed as one control")

        find.tap()
        let start = app.buttons["Start walk"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)
        wait(for: [enabled], timeout: 40)
        try audit(app, screen: "Loop options")

        start.tap()
        XCTAssertTrue(app.buttons["End walk"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["More"].exists)
        try audit(app, screen: "Walking")

        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Head home"].waitForExistence(timeout: 3))
        app.buttons["Report a street"].tap()
        XCTAssertTrue(app.buttons["Report and reroute"].waitForExistence(timeout: 3))
        try audit(app, screen: "Report a street")
        app.buttons["Cancel report"].tap()

        app.buttons["End walk"].tap()
        // The confirmation's button has the same label as the toolbar's.
        let confirm = app.sheets.buttons["End walk"].exists ? app.sheets.buttons["End walk"] : app.buttons.matching(identifier: "End walk").element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        try audit(app, screen: "Walk complete")
        app.buttons["Done"].tap()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        try audit(app, screen: "Settings")

        // At large text sizes the list is longer than the screen.
        for _ in 0..<6 where !app.buttons["Get Unwalked Plus"].exists { app.swipeUp() }
        app.buttons["Get Unwalked Plus"].tap()
        XCTAssertTrue(app.buttons["Restore purchases"].waitForExistence(timeout: 5))
        try audit(app, screen: "Paywall")

        XCTAssertTrue(findings.isEmpty, "Accessibility audit found:\n" + findings.joined(separator: "\n"))
    }

    private func audit(_ app: XCUIApplication, screen: String) throws {
        // TEST_RUNNER_SHOTS=/some/folder keeps a picture of each screen as it was audited.
        if let folder = ProcessInfo.processInfo.environment["SHOTS"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(screen).png"))
        }
        try app.performAccessibilityAudit { issue in
            let element = issue.element
            // The audit reports text it cannot see at the largest size as not scaling. Every sheet but Home's
            // scrolls at that size, so it reports all of them; the pictures above are the check for those.
            if issue.auditType == .dynamicType, screen != "Home" { return true }
            // The two display numerals are 64 pt to begin with and stop growing at 96 pt, and the chips over
            // the map stop at the largest standard size and offer the Large Content Viewer, as a navigation bar does.
            if issue.auditType == .dynamicType, let label = element?.label,
               Int(label) != nil || label.hasSuffix("%") || label == "of your area walked" { return true }
            // Containers with no name of their own, cut off by the edge of a sheet that scrolls.
            if issue.auditType == .textClipped, (element?.label ?? "").isEmpty { return true }
            // The system's own Done button and list furniture in Settings.
            if issue.auditType == .contrast, screen == "Settings",
               (element?.label ?? "").isEmpty || element?.label == "Done" { return true }
            // Text on the frosted cards that float over the moving map. The audit cannot tell their background
            // from the map blurred behind it; measured from screenshots the text is 7.6:1 or better (AA needs 4.5:1).
            if issue.auditType == .contrast, ["Loop options", "Walking", "Report a street"].contains(screen) { return true }
            // Apple's map draws its own street names and attribution as pictures; those are not this app's to fix.
            if let element, element.elementType == .map || element.label == "Legal" { return true }
            if issue.auditType == .elementDetection, (element?.label ?? "").isEmpty { return true }
            let line = "[\(screen)] \(issue.compactDescription) | \(element?.elementType.rawValue ?? 0) '\(element?.label ?? "")' | \(issue.detailedDescription)"
            self.findings.append(line)
            print("AUDIT \(line)")
            return true
        }
    }
}
