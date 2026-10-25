import SwiftUI

enum WorkspaceMotion {
    static let panelRevealDuration: TimeInterval = 0.16
    static let pageChange = Animation.easeOut(duration: 0.18)
    static let menuChange = Animation.easeOut(duration: 0.16)
    static let pageTransition = AnyTransition.opacity.combined(with: .offset(y: 5))
    static let menuTransition = AnyTransition.opacity.combined(with: .offset(y: 3))
    static let calendarTransition = AnyTransition.opacity
}
