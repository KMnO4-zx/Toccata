import SwiftUI

enum WorkspaceMotion {
    static let panelRevealDuration: TimeInterval = 0.16
    static let pageChange = Animation.easeOut(duration: 0.18)
    static let detailChange = Animation.easeOut(duration: 0.16)
    static let menuChange = Animation.easeOut(duration: 0.16)
    static let branchChange = Animation.easeInOut(duration: 0.2)
    static let taskReorder = Animation.easeInOut(duration: 0.28)
    static let editFocus = Animation.easeOut(duration: 0.16)
    static let editPress = Animation.easeOut(duration: 0.1)
    static let branchTransition = AnyTransition.opacity.combined(with: .offset(y: -4))
    static let pageTransition = AnyTransition.opacity.combined(with: .offset(y: 5))
    // Animate only the incoming editor to avoid overlapping task text.
    static let detailTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: 4)), removal: .identity
    )
    static let menuTransition = AnyTransition.opacity.combined(with: .offset(y: 3))
    static let calendarTransition = AnyTransition.opacity
}
