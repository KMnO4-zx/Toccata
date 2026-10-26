import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import toccata_studio

@MainActor
final class MarkdownWebEditorTests: XCTestCase {
    func testMarkdownRendersAndRoundTripsInEditableRegion() async throws {
        let editor = try await loadEditor()
        let markdown = "# 本周目标\n\n**完成设计** [参考链接](https://example.com)\n\n- 第一项\n- 第二项\n\n2. 第二项\n\n> 引用\n\n```swift\nlet title = \"**原样**\"\n```"
        _ = try await evaluate(editor, "setMarkdown(\(MarkdownTextEditor.javascriptString(markdown)))")
        let html = try await evaluate(editor, "document.getElementById('editor').innerHTML")
        XCTAssertTrue(html.contains("<h1>本周目标</h1>"))
        XCTAssertTrue(html.contains("<strong>完成设计</strong>"))
        XCTAssertTrue(html.contains("href=\"https://example.com\""))
        XCTAssertTrue(html.contains("<ol start=\"2\">"))
        XCTAssertTrue(html.contains("<blockquote>引用</blockquote>"))
        XCTAssertTrue(html.contains("let title = \"**原样**\""))
        let roundTrip = try await evaluate(editor, "getMarkdown()")
        let contentEditable = try await evaluate(editor, "document.getElementById('editor').contentEditable")
        XCTAssertEqual(roundTrip, markdown)
        XCTAssertEqual(contentEditable, "true")
    }

    func testTypingBecomesFormattedWithoutChangingModes() async throws {
        let editor = try await loadEditor()
        _ = try await evaluate(editor, """
            document.getElementById('editor').focus();
            document.execCommand('insertText', false, '**加粗**');
            normalizeEditor();
        """)
        let html = try await evaluate(editor, "document.getElementById('editor').innerHTML")
        XCTAssertTrue(html.contains("<strong>加粗</strong>"))
        let roundTrip = try await evaluate(editor, "getMarkdown()")
        let contentEditable = try await evaluate(editor, "document.getElementById('editor').contentEditable")
        XCTAssertEqual(roundTrip, "**加粗**")
        XCTAssertEqual(contentEditable, "true")
    }

    func testPastedMarkdownFormsBlocksIncrementally() async throws {
        let editor = try await loadEditor()
        let markdown = "## 中文标题\n\n- **中文加粗**"
        _ = try await evaluate(editor, "document.getElementById('editor').focus(); insertPlainText(\(MarkdownTextEditor.javascriptString(markdown))); window.beforeMultilineNormalization = editor.innerHTML; normalizeEditor();")
        let html = try await evaluate(editor, "document.getElementById('editor').innerHTML")
        XCTAssertTrue(html.contains("<h2>中文标题</h2>"))
        XCTAssertTrue(html.contains("<ul><li><strong>中文加粗</strong></li></ul>"))
        let roundTrip = try await evaluate(editor, "getMarkdown()")
        let originalDOM = try await evaluate(editor, "window.beforeMultilineNormalization")
        XCTAssertEqual(roundTrip, markdown, originalDOM)
    }

    func testConsecutiveTypingKeepsEditorFocused() async throws {
        let editor = try await loadEditor()
        _ = try await evaluate(editor, "document.getElementById('editor').focus()")
        _ = try await evaluate(editor, "document.execCommand('insertText', false, 'a'); normalizeEditor(); window.initialParagraph = document.getElementById('editor').firstChild; true")
        for character in ["b", "c"] {
            _ = try await evaluate(editor, "document.execCommand('insertText', false, '\(character)'); normalizeEditor();")
            let sameParagraph = try await evaluate(editor, "document.getElementById('editor').firstChild === window.initialParagraph")
            XCTAssertEqual(sameParagraph, "true")
        }
        let markdown = try await evaluate(editor, "getMarkdown()")
        let activeElement = try await evaluate(editor, "document.activeElement.id")
        XCTAssertEqual(markdown, "abc")
        XCTAssertEqual(activeElement, "editor")
    }

    func testReturnThenPauseKeepsEmptyLineAndCaret() async throws {
        let editor = try await loadEditor()
        _ = try await evaluate(editor, """
            setMarkdown('给 Agentic RL Lab 做贡献');
            focusEditor(); setCaret(editor.textContent.length);
            document.execCommand('insertParagraph', false);
        """)
        try await Task.sleep(nanoseconds: 500_000_000)

        let markdown = try await evaluate(editor, "getMarkdown()")
        let caretOnEmptyLine = try await evaluate(editor, """
            (() => {
                const node = window.getSelection().anchorNode;
                const block = (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement).closest('p, div');
                return block !== editor && block.textContent === '' && block.querySelector('br') !== null;
            })()
        """)
        XCTAssertEqual(markdown, "给 Agentic RL Lab 做贡献\n\n")
        XCTAssertEqual(caretOnEmptyLine, "true")

        _ = try await evaluate(editor, "document.execCommand('insertText', false, '第二行');")
        try await Task.sleep(nanoseconds: 350_000_000)
        let continued = try await evaluate(editor, "getMarkdown()")
        XCTAssertEqual(continued, "给 Agentic RL Lab 做贡献\n\n第二行")
    }

    func testEmptyLineSurvivesBindingEchoFlushAndReopening() async throws {
        let (editor, coordinator, state) = try await loadCoordinatedEditor()
        _ = try await evaluate(editor, "focusEditor(); document.execCommand('insertText', false, '第一行');")
        try await Task.sleep(nanoseconds: 350_000_000)
        coordinator.update(text: state.text, isFocused: true, fontSize: 12, textColor: .labelColor)
        _ = try await evaluate(editor, "document.execCommand('insertParagraph', false);")
        try await Task.sleep(nanoseconds: 500_000_000)
        coordinator.update(text: state.text, isFocused: true, fontSize: 12, textColor: .labelColor)

        let saved = await coordinator.flushPendingMarkdown()
        XCTAssertTrue(saved)
        XCTAssertEqual(state.text, "第一行\n\n")
        let externalRenders = try await evaluate(editor, "String(window.externalRenders)")
        XCTAssertEqual(externalRenders, "0")

        let reopened = try await loadEditor()
        _ = try await evaluate(reopened, "setMarkdown(\(MarkdownTextEditor.javascriptString(state.text)))")
        let roundTrip = try await evaluate(reopened, "getMarkdown()")
        XCTAssertEqual(roundTrip, state.text)
        let lastLineIsEmpty = try await evaluate(reopened, "editor.lastElementChild.textContent === '' && editor.lastElementChild.querySelector('br') !== null")
        XCTAssertEqual(lastLineIsEmpty, "true")
    }

    func testEmptyParagraphsRoundTripWithoutLosingOrAddingLines() async throws {
        let editor = try await loadEditor()
        for markdown in ["", "\n\n", "\n\n第一行", "第一行\n\n", "第一行\n\n\n\n", "第一行\n\n\n\n第二行"] {
            _ = try await evaluate(editor, "setMarkdown(\(MarkdownTextEditor.javascriptString(markdown)))")
            for _ in 0..<3 {
                _ = try await evaluate(editor, "normalizeEditor();")
                let saved = try await evaluate(editor, "getMarkdown()")
                XCTAssertEqual(saved, markdown)
                _ = try await evaluate(editor, "setMarkdown(\(MarkdownTextEditor.javascriptString(saved)))")
            }
        }
    }

    func testRepeatedReturnPausesPreserveEveryEmptyParagraph() async throws {
        let editor = try await loadEditor()
        _ = try await evaluate(editor, "setMarkdown('第一行'); focusEditor(); setCaret(editor.textContent.length);")
        for count in 1...3 {
            _ = try await evaluate(editor, "document.execCommand('insertParagraph', false);")
            try await Task.sleep(nanoseconds: 350_000_000)
            let markdown = try await evaluate(editor, "getMarkdown()")
            XCTAssertEqual(markdown, "第一行" + String(repeating: "\n\n", count: count))
        }
        _ = try await evaluate(editor, "document.execCommand('insertText', false, '最后一行');")
        try await Task.sleep(nanoseconds: 350_000_000)
        let continued = try await evaluate(editor, "getMarkdown()")
        XCTAssertEqual(continued, "第一行" + String(repeating: "\n\n", count: 3) + "最后一行")
    }

    func testPastedPlainLinesStaySeparateWithoutAddingBlankParagraphs() async throws {
        let editor = try await loadEditor()
        _ = try await evaluate(editor, "focusEditor(); insertPlainText('第一行\\n第二行'); normalizeEditor();")
        let markdown = try await evaluate(editor, "getMarkdown()")
        XCTAssertEqual(markdown, "第一行\n\n第二行")
    }

    func testShiftReturnKeepsOneNewLineAfterPausing() async throws {
        let editor = try await loadEditor()
        _ = try await evaluate(editor, "setMarkdown('第一行'); focusEditor(); setCaret(editor.textContent.length); document.execCommand('insertLineBreak', false);")
        let originalDOM = try await evaluate(editor, "editor.innerHTML")
        try await Task.sleep(nanoseconds: 350_000_000)
        let markdown = try await evaluate(editor, "getMarkdown()")
        XCTAssertEqual(markdown, "第一行\n\n", originalDOM)
        _ = try await evaluate(editor, "document.execCommand('insertText', false, '第二行');")
        try await Task.sleep(nanoseconds: 350_000_000)
        let continued = try await evaluate(editor, "getMarkdown()")
        XCTAssertEqual(continued, "第一行\n\n第二行")
    }

    func testComposingInputDefersNormalization() async throws {
        let editor = try await loadEditor()
        _ = try await evaluate(editor, "setMarkdown(''); document.getElementById('editor').innerHTML = '待办';")
        _ = try await evaluate(editor, "document.getElementById('editor').dispatchEvent(new InputEvent('input', { data: '待', isComposing: true }));")
        try await Task.sleep(nanoseconds: 350_000_000)
        let during = try await evaluate(editor, "document.getElementById('editor').innerHTML")
        XCTAssertEqual(during, "待办")
        _ = try await evaluate(editor, "document.getElementById('editor').dispatchEvent(new InputEvent('input', { data: '办', isComposing: false }));")
        try await Task.sleep(nanoseconds: 350_000_000)
        let after = try await evaluate(editor, "getMarkdown()")
        XCTAssertEqual(after, "待办")
    }

    func testCompositionEndDoesNotNormalizeImmediately() async throws {
        let editor = try await loadEditor()
        _ = try await evaluate(editor, "setMarkdown(''); document.getElementById('editor').innerHTML = '待办'; focusEditor(); setCaret(document.getElementById('editor').textContent.length);")
        _ = try await evaluate(editor, """
            document.getElementById('editor').dispatchEvent(new CompositionEvent('compositionstart'));
            document.execCommand('insertText', false, 'n');
            normalizeEditor();
        """)
        let during = try await evaluate(editor, "document.getElementById('editor').innerHTML")
        XCTAssertEqual(during, "待办n")
        _ = try await evaluate(editor, "document.getElementById('editor').dispatchEvent(new CompositionEvent('compositionend'));")
        let immediatelyAfter = try await evaluate(editor, "document.getElementById('editor').innerHTML")
        XCTAssertEqual(immediatelyAfter, "待办n")
        _ = try await evaluate(editor, "normalizeEditor();")
        let normalized = try await evaluate(editor, "getMarkdown()")
        XCTAssertEqual(normalized, "待办n")
    }

    func testTypingAfterFormattingStaysInsideList() async throws {
        let editor = try await loadEditor()
        _ = try await evaluate(editor, """
            document.getElementById('editor').focus();
            insertPlainText('## 中文标题\\n\\n- **中文加粗**');
            normalizeEditor();
            document.execCommand('insertText', false, '继续输入');
        """)
        let html = try await evaluate(editor, "document.getElementById('editor').innerHTML")
        let markdown = try await evaluate(editor, "getMarkdown()")
        XCTAssertTrue(html.contains("<ul><li><strong>中文加粗</strong>继续输入</li></ul>"), html)
        XCTAssertEqual(markdown, "## 中文标题\n\n- **中文加粗**继续输入")
    }

    func testInProgressMarkdownDoesNotCauseExternalRerender() async throws {
        let (editor, coordinator, state) = try await loadCoordinatedEditor()
        _ = try await evaluate(editor, "document.getElementById('editor').focus()")
        for character in ["[", "a"] {
            _ = try await evaluate(editor, "document.execCommand('insertText', false, '\(character)')")
            try await Task.sleep(nanoseconds: 350_000_000)
            coordinator.update(text: state.text, isFocused: true, fontSize: 12, textColor: .labelColor)
        }
        let renderCount = try await evaluate(editor, "String(window.externalRenders)")
        let visibleText = try await evaluate(editor, "document.getElementById('editor').textContent")
        let markdown = try await evaluate(editor, "getMarkdown()")
        XCTAssertEqual(renderCount, "0")
        XCTAssertEqual(visibleText, "[a")
        XCTAssertEqual(markdown, state.text)
    }

    func testFlushReadsFinalTypingBeforeDebounceAndDoesNotRerenderOldBinding() async throws {
        let (editor, coordinator, state) = try await loadCoordinatedEditor()
        _ = try await evaluate(editor, """
            focusEditor();
            document.execCommand('insertText', false, '最后一段描述');
            clearTimeout(normalizeTimer);
        """)
        XCTAssertEqual(state.text, "")
        let saved = await coordinator.flushPendingMarkdown()
        XCTAssertTrue(saved)
        XCTAssertEqual(state.text, "最后一段描述")
        coordinator.update(text: state.text, isFocused: true, fontSize: 12, textColor: .labelColor)
        let visibleText = try await evaluate(editor, "document.getElementById('editor').textContent")
        let renderCount = try await evaluate(editor, "String(window.externalRenders)")
        XCTAssertEqual(visibleText, "最后一段描述")
        XCTAssertEqual(renderCount, "0")
    }

    func testCompositionSyncDoesNotInterruptFollowingInput() async throws {
        let (editor, coordinator, state) = try await loadCoordinatedEditor()
        _ = try await evaluate(editor, """
            document.getElementById('editor').focus();
            document.getElementById('editor').dispatchEvent(new CompositionEvent('compositionstart'));
            document.execCommand('insertText', false, '你');
        """)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(state.text, "")
        _ = try await evaluate(editor, "document.getElementById('editor').dispatchEvent(new CompositionEvent('compositionend'))")
        try await Task.sleep(nanoseconds: 350_000_000)
        coordinator.update(text: state.text, isFocused: true, fontSize: 12, textColor: .labelColor)
        _ = try await evaluate(editor, "document.execCommand('insertText', false, 'a')")
        try await Task.sleep(nanoseconds: 350_000_000)
        coordinator.update(text: state.text, isFocused: true, fontSize: 12, textColor: .labelColor)
        let visibleText = try await evaluate(editor, "document.getElementById('editor').textContent")
        let markdown = try await evaluate(editor, "getMarkdown()")
        let renderCount = try await evaluate(editor, "String(window.externalRenders)")
        XCTAssertEqual(visibleText, "你a")
        XCTAssertEqual(markdown, state.text)
        XCTAssertEqual(renderCount, "0")
    }

    func testAppearanceSwitchPreservesUncommittedCompositionAndSelection() async throws {
        let (editor, coordinator, state) = try await loadCoordinatedEditor()
        _ = try await evaluate(editor, """
            focusEditor();
            editor.dispatchEvent(new CompositionEvent('compositionstart'));
            document.execCommand('insertText', false, '正在输入');
            window.compositionHTML = editor.innerHTML;
            window.compositionNode = window.getSelection().anchorNode;
            window.compositionOffset = window.getSelection().anchorOffset;
        """)
        XCTAssertEqual(state.text, "")

        for scheme in [ColorScheme.dark, .light] {
            coordinator.update(text: state.text, isFocused: true, fontSize: 12,
                               textColor: .labelColor, colorScheme: scheme)
            let result = try await evaluate(editor, """
                JSON.stringify({
                    scheme: getComputedStyle(document.documentElement).colorScheme,
                    unchangedHTML: editor.innerHTML === window.compositionHTML,
                    unchangedNode: window.getSelection().anchorNode === window.compositionNode,
                    unchangedOffset: window.getSelection().anchorOffset === window.compositionOffset,
                    composing: composing,
                    renders: window.externalRenders
                })
            """)
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
            XCTAssertEqual(values["scheme"] as? String, scheme == .dark ? "dark" : "light")
            XCTAssertEqual(values["unchangedHTML"] as? Bool, true)
            XCTAssertEqual(values["unchangedNode"] as? Bool, true)
            XCTAssertEqual(values["unchangedOffset"] as? Bool, true)
            XCTAssertEqual(values["composing"] as? Bool, true)
            XCTAssertEqual(values["renders"] as? Int, 0)
            XCTAssertEqual(state.text, "")
        }

        _ = try await evaluate(editor, "editor.dispatchEvent(new CompositionEvent('compositionend')); clearTimeout(normalizeTimer);")
        let saved = await coordinator.flushPendingMarkdown()
        XCTAssertTrue(saved)
        XCTAssertEqual(state.text, "正在输入")
    }

    func testMainDetailKeepsFocusAfterDraftUpdates() async throws {
        let (store, id, task) = try focusFixture()
        let view = TaskDetailView(task: task, onSelect: { _ in }).environmentObject(store)
        try await assertContinuousEditing(view, store: store, id: id)
    }

    func testFloatingDetailKeepsFocusAfterDraftUpdates() async throws {
        let (store, id, _) = try focusFixture()
        let presentation = MenuTaskPresentation()
        presentation.selectTask(id)
        let view = FloatingTaskEditor().environmentObject(store).environmentObject(presentation)
        try await assertContinuousEditing(view, store: store, id: id)
    }

    private func focusFixture() throws -> (TaskStore, String, TodoTask) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(databaseURL: directory.appendingPathComponent("tasks.sqlite"), completionFeedback: {})
        let id = try XCTUnwrap(store.addTask(title: "焦点验证"))
        let task = try XCTUnwrap(store.task(id: id))
        return (store, id, task)
    }

    private func assertContinuousEditing<V: View>(_ view: V, store: TaskStore, id: String) async throws {
        let (window, editor) = try await loadWindowEditor(view)
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        window.makeFirstResponder(editor)
        _ = try await evaluate(editor, "focusEditor(); document.execCommand('insertText', false, 'a');")
        try await waitForDetails("a", store: store, id: id)
        _ = try await evaluate(editor, "document.execCommand('insertText', false, 'b');")
        try await waitForDetails("ab", store: store, id: id)
        let markdown = try await evaluate(editor, "getMarkdown()")
        let activeElement = try await evaluate(editor, "document.activeElement.id")
        XCTAssertEqual(markdown, "ab")
        XCTAssertEqual(activeElement, "editor")
        XCTAssertEqual(store.task(id: id)?.details, "ab")

        let inputClient = try XCTUnwrap(editor as AnyObject as? NSTextInputClient)
        inputClient.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(nanoseconds: 350_000_000)
        let markedMarkdown = try await evaluate(editor, "getMarkdown()")
        XCTAssertEqual(markedMarkdown, "abni")
        XCTAssertEqual(store.task(id: id)?.details, "ab")
        inputClient.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        inputClient.unmarkText()
        try await waitForDetails("ab你", store: store, id: id)
        inputClient.insertText("！", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitForDetails("ab你！", store: store, id: id)
        let committedMarkdown = try await evaluate(editor, "getMarkdown()")
        let committedFocus = try await evaluate(editor, "document.activeElement.id")
        XCTAssertEqual(committedMarkdown, "ab你！")
        XCTAssertEqual(committedFocus, "editor")
        XCTAssertEqual(store.task(id: id)?.details, "ab你！")

        _ = try await evaluate(editor, "document.execCommand('insertParagraph', false);")
        try await waitForDetails("ab你！\n\n", store: store, id: id)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(store.task(id: id)?.details, "ab你！\n\n")
        _ = try await evaluate(editor, "document.execCommand('insertText', false, '下一行');")
        try await waitForDetails("ab你！\n\n下一行", store: store, id: id)
        let multilineMarkdown = try await evaluate(editor, "getMarkdown()")
        XCTAssertEqual(multilineMarkdown, "ab你！\n\n下一行")
        XCTAssertEqual(store.task(id: id)?.details, multilineMarkdown)
    }

    private func waitForDetails(_ expected: String, store: TaskStore, id: String) async throws {
        for _ in 0..<40 {
            if store.task(id: id)?.details == expected { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func loadWindowEditor<V: View>(_ view: V) async throws -> (NSWindow, WKWebView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<50 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let editor = firstWebView(in: window.contentView),
               try await evaluate(editor, "document.readyState === 'complete' && typeof focusEditor === 'function'") == "true" {
                return (window, editor)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        window.close()
        throw NSError(domain: "MarkdownWebEditorTests", code: 1)
    }

    private func firstWebView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let webView = firstWebView(in: child) { return webView }
        }
        return nil
    }

    private func loadCoordinatedEditor() async throws -> (WKWebView, MarkdownEditorCoordinator, MarkdownBindingState) {
        let state = MarkdownBindingState()
        let text = Binding(get: { state.text }, set: { state.text = $0 })
        let focused = Binding(get: { state.focused }, set: { state.focused = $0 })
        let coordinator = MarkdownEditorCoordinator(text: text, isFocused: focused)
        let editor = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        let loaded = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKWebView, Error>) in
            var delegate: NavigationWaiter?
            delegate = NavigationWaiter(
                onFinish: {
                    _ = delegate
                    continuation.resume(returning: editor)
                },
                onFailure: {
                    _ = delegate
                    continuation.resume(throwing: $0)
                }
            )
            delegate?.forwardingDelegate = coordinator
            coordinator.attach(to: editor, placeholder: "详情")
            editor.navigationDelegate = delegate
        }
        _ = try await evaluate(loaded, """
            window.externalRenders = 0;
            const renderFromSwift = setMarkdown;
            setMarkdown = function(markdown) {
                window.externalRenders += 1;
                renderFromSwift(markdown);
            };
            true;
        """)
        return (editor, coordinator, state)
    }

    private func loadEditor() async throws -> WKWebView {
        let editor = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                               configuration: WKWebViewConfiguration())
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKWebView, Error>) in
            var delegate: NavigationWaiter?
            delegate = NavigationWaiter(
                onFinish: {
                    _ = delegate
                    continuation.resume(returning: editor)
                },
                onFailure: {
                    _ = delegate
                    continuation.resume(throwing: $0)
                }
            )
            editor.navigationDelegate = delegate
            editor.loadHTMLString(MarkdownTextEditor.pageHTML(placeholder: "详情"), baseURL: nil)
        }
    }

    private func evaluate(_ editor: WKWebView, _ script: String) async throws -> String {
        let result = try await editor.evaluateJavaScript(script)
        if let string = result as? String { return string }
        if let boolean = result as? Bool { return boolean ? "true" : "false" }
        return String(describing: result ?? "")
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    let onFailure: (Error) -> Void
    weak var forwardingDelegate: WKNavigationDelegate?

    init(onFinish: @escaping () -> Void, onFailure: @escaping (Error) -> Void) {
        self.onFinish = onFinish
        self.onFailure = onFailure
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        forwardingDelegate?.webView?(webView, didFinish: navigation)
        onFinish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        forwardingDelegate?.webView?(webView, didFail: navigation, withError: error)
        onFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        forwardingDelegate?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
        onFailure(error)
    }
}

private final class MarkdownBindingState {
    var text = ""
    var focused = false
}
