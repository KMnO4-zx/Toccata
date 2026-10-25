import AppKit
import CoreServices
import XCTest
@testable import toccata_studio

final class ApplicationLaunchContextTests: XCTestCase {
    private func event(eventClass: AEEventClass = AEEventClass(kCoreEventClass),
                       eventID: AEEventID = AEEventID(kAEOpenApplication),
                       reason: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: eventClass, eventID: eventID,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let reason { event.setParam(reason, forKeyword: AEKeyword(keyAEPropData)) }
        return event
    }

    func testRecognizesLoginItemEnumOnOpenApplicationEvent() {
        let loginEvent = event(reason: NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)))
        XCTAssertTrue(ApplicationLaunchContext.isLoginItemLaunch(loginEvent))
    }

    func testManualOrMissingLaunchEventIsNotLoginLaunch() {
        XCTAssertFalse(ApplicationLaunchContext.isLoginItemLaunch(nil))
        XCTAssertFalse(ApplicationLaunchContext.isLoginItemLaunch(event()))
        XCTAssertFalse(ApplicationLaunchContext.isLoginItemLaunch(NSAppleEventDescriptor.null()))
    }

    func testBooleanPropertyDoesNotMasqueradeAsLoginItemReason() {
        XCTAssertFalse(ApplicationLaunchContext.isLoginItemLaunch(event(reason: NSAppleEventDescriptor(boolean: true))))
        XCTAssertFalse(ApplicationLaunchContext.isLoginItemLaunch(event(reason: NSAppleEventDescriptor(boolean: false))))
    }

    func testReopenOrOtherEventCannotHideUserRequestedWindow() {
        let reason = NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem))
        XCTAssertFalse(ApplicationLaunchContext.isLoginItemLaunch(event(eventID: AEEventID(kAEReopenApplication), reason: reason)))
        XCTAssertFalse(ApplicationLaunchContext.isLoginItemLaunch(event(eventClass: AEEventClass(kAECoreSuite), reason: reason)))
    }

    func testServiceLaunchIsNotClassifiedAsLoginItem() {
        let serviceEvent = event(reason: NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsServiceItem)))
        XCTAssertFalse(ApplicationLaunchContext.isLoginItemLaunch(serviceEvent))
    }
}
