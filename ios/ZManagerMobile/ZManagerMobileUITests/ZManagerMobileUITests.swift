import XCTest

final class ZManagerMobileUITests: XCTestCase {
    func testArchiveAndLocalSendWorkbenchesAreReachable() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["ZManager"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Share on local network"].exists)
        XCTAssertTrue(app.staticTexts["Create archive"].exists)
    }

    func testPrimaryControlsExposeStableAccessibilityLabels() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Load nested fixture"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Run debug batch extraction"].exists)
        XCTAssertTrue(app.buttons["Choose photos or videos"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["localSendPanel"].exists)
        XCTAssertTrue(app.buttons["aboutAndHelp"].exists)
        app.buttons["aboutAndHelp"].tap()
        XCTAssertTrue(app.staticTexts["About ZManager"].waitForExistence(timeout: 5))
    }
}
