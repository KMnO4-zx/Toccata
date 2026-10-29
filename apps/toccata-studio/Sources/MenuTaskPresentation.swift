import AppKit
import Combine

enum MenuEditorField: Equatable {
    case description
    case child
}

struct MenuEditorFocusRequest: Equatable {
    let field: MenuEditorField
    let token = UUID()
}

/// Shared selection and focus for the task list and its companion editor.
@MainActor
final class MenuTaskPresentation: ObservableObject {
    @Published var page: MenuPanelPage
    @Published var activityTab: MenuActivityTab = .keyboard
    @Published private(set) var isMenuVisible = false
    private let settings: MenuBarSettings
    @Published var selectedTaskID: String?
    @Published private(set) var isEditorVisible = false
    @Published var focusRequest: MenuEditorFocusRequest?
    @Published var listFocusRequest = 0
    @Published var expandedTaskIDs: Set<String> = []
    @Published var openGeneration = UUID()
    @Published var panelSize = CGSize(width: 312, height: 554)

    /// SwiftUI popovers may have no public parent-window relationship. Register
    /// their hosts without retaining them so clicks remain inside the menu pair.
    let companionWindows = NSHashTable<NSWindow>.weakObjects()

    var rowFrames: [String: CGRect] = [:] {
        didSet { onAnchorsChanged?() }
    }
    var onShowEditor: ((String, MenuEditorField?) -> Void)?
    var onDismissEditor: (() -> Void)?
    var onFocusList: (() -> Void)?
    var onOpenWorkbench: (() -> Void)?
    var onDismissMenu: (() -> Void)?
    var onAnchorsChanged: (() -> Void)?

    init(settings: MenuBarSettings? = nil) {
        self.settings = settings ?? .shared
        page = self.settings.defaultPage
    }

    func prepareForOpening() {
        page = settings.defaultPage
        selectedTaskID = nil
        editorDidHide()
        rowFrames = [:]
        isMenuVisible = true
        openGeneration = UUID()
    }

    func menuDidHide() { isMenuVisible = false }
    func dismissMenu() { onDismissMenu?() }

    func selectTask(_ id: String, focus: MenuEditorField? = nil) {
        selectedTaskID = id
        focusRequest = focus.map { MenuEditorFocusRequest(field: $0) }
        isEditorVisible = true
        onShowEditor?(id, focus)
    }

    /// Only task-row clicks toggle; keyboard actions always open their editor.
    func toggleTask(_ id: String) {
        if selectedTaskID == id && isEditorVisible {
            dismissEditor()
        } else {
            selectTask(id)
        }
    }

    func dismissEditor() {
        editorDidHide()
        onDismissEditor?()
    }

    /// Also called when the native panel closes with the menu or its task is deleted.
    func editorDidHide() {
        if isEditorVisible { isEditorVisible = false }
        if focusRequest != nil { focusRequest = nil }
    }

    func requestListFocus() {
        focusRequest = nil
        onFocusList?()
        listFocusRequest += 1
    }

    func openWorkbench() { onOpenWorkbench?() }
}
