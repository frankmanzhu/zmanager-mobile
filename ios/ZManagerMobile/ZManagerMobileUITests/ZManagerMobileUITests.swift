import XCTest

final class ZManagerMobileUITests: XCTestCase {
    func testArchiveAndLocalSendWorkbenchesAreReachable() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["ZManager"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Share on local network"].exists)
        XCTAssertTrue(app.staticTexts["Create archive"].exists)
    }
}
