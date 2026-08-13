import XCTest

final class ZManagerMobileUITests: XCTestCase {
    func testArchiveAndLocalSendWorkbenchesAreReachable() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["ZManager"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Share on local network"].exists)
        XCTAssertTrue(app.staticTexts["Create archive"].exists)
    }

    func testEncryptedRepackagingAcceptsTypedPasswordAndVerifiesOutput() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Load encrypted fixture"].tap()
        XCTAssertTrue(app.staticTexts["ZIP - 1 entries"].waitForExistence(timeout: 10))
        app.staticTexts["maestro-inner.zip"].tap()
        app.buttons["Create archive from selection"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Ready to repackage'"))
            .firstMatch.waitForExistence(timeout: 10))
        app.buttons["Start"].tap()

        let password = app.secureTextFields["Archive password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap()
        for character in "v2testpassword" {
            password.typeText(String(character))
        }
        XCTAssertEqual((password.value as? String)?.count ?? 0, 14)
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Ready to repackage'"))
            .firstMatch.waitForExistence(timeout: 10))
        app.buttons["Start"].tap()
        let verified = app.staticTexts["Verified"]
        if !verified.waitForExistence(timeout: 30) {
            print(app.debugDescription)
            XCTFail("Expected Verified status")
        }
    }

    func testDebugFolderCreationCompletesAndVerifiesOutput() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Create debug folder archive"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'entries'"))
            .firstMatch.waitForExistence(timeout: 10))
        app.buttons["Start creation"].tap()

        XCTAssertTrue(app.staticTexts["Verified"].waitForExistence(timeout: 30))
    }
}
