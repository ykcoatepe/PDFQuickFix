@testable import PDFQuickFix
import XCTest

final class AppLaunchWindowPolicyTests: XCTestCase {
    func testFinderQuickActionReceiptCountsAsUserFacingWindow() {
        XCTAssertTrue(AppLaunchWindowPolicy.isUserFacingWindow(
            title: AppLaunchWindowPolicy.finderReceiptWindowTitle,
            isVisible: true,
            canBecomeMainOrKey: true
        ))
    }

    func testHiddenReceiptDoesNotCountAsUserFacingWindow() {
        XCTAssertFalse(AppLaunchWindowPolicy.isUserFacingWindow(
            title: AppLaunchWindowPolicy.finderReceiptWindowTitle,
            isVisible: false,
            canBecomeMainOrKey: true
        ))
    }

    func testMinimizedMainWindowCountsAsUserFacingWindow() {
        XCTAssertTrue(AppLaunchWindowPolicy.isUserFacingWindow(
            title: AppLaunchWindowPolicy.mainWindowTitle,
            isVisible: false,
            canBecomeMainOrKey: true,
            isMiniaturized: true
        ))
    }

    func testDockReopenWithNoVisibleWindowsIsHandledByAppDelegate() {
        XCTAssertFalse(AppLaunchWindowPolicy.shouldAllowDefaultReopen(hasUserFacingWindow: false))
    }

    func testNoUserFacingWindowRequiresFallbackWindow() {
        XCTAssertTrue(AppLaunchWindowPolicy.shouldOpenFallbackWindow(hasUserFacingWindow: false))
    }

    func testInitialLaunchDoesNotRequireFallbackWindow() {
        XCTAssertFalse(AppLaunchWindowPolicy.shouldOpenFallbackWindow(
            hasUserFacingWindow: false,
            trigger: .initialLaunch
        ))
    }

    func testFirstActivationUsesInitialLaunchFallbackPolicy() {
        let trigger = AppLaunchWindowPolicy.activationFallbackTrigger(hasCompletedInitialActivation: false)

        XCTAssertEqual(trigger, .initialLaunch)
        XCTAssertFalse(AppLaunchWindowPolicy.shouldOpenFallbackWindow(
            hasUserFacingWindow: false,
            trigger: trigger
        ))
    }

    func testLaterActivationCanOpenFallbackWindow() {
        let trigger = AppLaunchWindowPolicy.activationFallbackTrigger(hasCompletedInitialActivation: true)

        XCTAssertEqual(trigger, .activation)
        XCTAssertTrue(AppLaunchWindowPolicy.shouldOpenFallbackWindow(
            hasUserFacingWindow: false,
            trigger: trigger
        ))
    }

    func testExistingUserFacingWindowDoesNotRequireFallbackWindow() {
        XCTAssertFalse(AppLaunchWindowPolicy.shouldOpenFallbackWindow(hasUserFacingWindow: true))
    }

    func testDockReopenWithUserFacingWindowAllowsDefaultHandling() {
        XCTAssertTrue(AppLaunchWindowPolicy.shouldAllowDefaultReopen(hasUserFacingWindow: true))
    }

    func testAuxiliaryWindowDoesNotCountAsUserFacingWindow() {
        XCTAssertFalse(AppLaunchWindowPolicy.isUserFacingWindow(
            title: "AI Activity",
            isVisible: true,
            canBecomeMainOrKey: true
        ))
    }
}
