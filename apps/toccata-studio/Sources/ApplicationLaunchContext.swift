import AppKit
import CoreServices

/// Launch Services supplies an enumerated launch reason in keyAEPropData.
/// Read the current event during applicationDidFinishLaunching; App.init may run
/// before the open-application Apple event is being handled.
/// https://developer.apple.com/documentation/coreservices/1556410-launch_apple_event_constants
struct ApplicationLaunchContext {
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    @MainActor
    static var currentIsLoginItemLaunch: Bool {
        isLoginItemLaunch(NSAppleEventManager.shared().currentAppleEvent)
    }
}
