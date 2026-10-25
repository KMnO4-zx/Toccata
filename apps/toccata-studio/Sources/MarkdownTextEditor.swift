import AppKit
import SwiftUI
import WebKit

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool
    var fontSize: CGFloat = 12
    var textColor = NSColor.labelColor

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.underPageBackgroundColor = .clear
        context.coordinator.attach(to: view, placeholder: placeholder)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(text: text, isFocused: isFocused, fontSize: fontSize, textColor: textColor)
    }

    func makeCoordinator() -> MarkdownEditorCoordinator {
        MarkdownEditorCoordinator(text: $text, isFocused: $isFocused)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: MarkdownEditorCoordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "markdownChanged")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "focusChanged")
    }

    static func pageHTML(placeholder: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        * { box-sizing: border-box; }
        html, body { margin: 0; width: 100%; height: 100%; background: transparent; overflow: hidden; }
        body { font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; }
        #editor {
            position: relative;
            width: 100%;
            height: 100%;
            padding: 6px 8px;
            overflow: auto;
            outline: none;
            color: #333333;
            font-size: 12px;
            line-height: 1.55;
            tab-size: 4;
            -webkit-font-smoothing: antialiased;
        }
        #editor:empty::before {
            content: attr(data-placeholder);
            position: absolute;
            top: 6px;
            left: 8px;
            right: 8px;
            color: #a6a6a6;
            pointer-events: none;
        }
        #editor::-webkit-scrollbar { width: 8px; height: 8px; }
        #editor::-webkit-scrollbar-track { background: transparent; }
        #editor::-webkit-scrollbar-thumb {
            background: #dbdbdb;
            border: 2px solid transparent;
            border-radius: 4px;
            background-clip: content-box;
        }
        #editor::-webkit-scrollbar-button { display: none; }
        #editor::-webkit-scrollbar-corner { background: transparent; }
        p { margin: 0 0 8px; }
        h1, h2, h3, h4, h5, h6 { margin: 0 0 8px; line-height: 1.35; }
        h1 { font-size: 18px; }
        h2 { font-size: 16px; }
        h3 { font-size: 14px; }
        h4, h5, h6 { font-size: 12px; }
        ul, ol { margin: 0 0 8px; padding-left: 22px; }
        blockquote { margin: 0 0 8px; padding-left: 8px; border-left: 2px solid #d3d3d3; color: #777777; }
        a { color: #4772fa; text-decoration: underline; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; }
        pre {
            margin: 0 0 8px;
            padding: 10px;
            overflow: auto;
            border-radius: 7px;
            background: #f5f5f5;
            white-space: pre-wrap;
        }
        pre code { font: inherit; }
        hr { border: 0; border-top: 1px solid #dddddd; margin: 10px 0; }
        </style>
        </head>
        <body>
        <div id="editor" contenteditable="true" spellcheck="false" autocorrect="off" autocomplete="off" autocapitalize="off"></div>
        <script>
        const editor = document.getElementById('editor');
        editor.dataset.placeholder = \(javascriptString(placeholder));
        let composing = false;
        let normalizeTimer = null;

        function esc(text) {
            return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
        }

        function inline(text) {
            return text.split(/(`[^`\\n]+`)/g).map(part => {
                if (part.length > 2 && part.startsWith('`') && part.endsWith('`')) {
                    return '<code>' + esc(part.slice(1, -1)) + '</code>';
                }
                return formatInline(part);
            }).join('');
        }

        function unescapeMarkdown(text) {
            let result = '';
            for (let index = 0; index < text.length; index += 1) {
                const character = text[index];
                if (character === String.fromCharCode(92) && index + 1 < text.length
                    && '`*_[]~'.includes(text[index + 1])) {
                    result += text[index + 1];
                    index += 1;
                } else {
                    result += character;
                }
            }
            return result;
        }

        function formatInline(text) {
            let value = esc(unescapeMarkdown(text));
            value = value.replace(/\\[([^\\]]+)\\]\\((https?:\\/\\/[^\\s)]+)\\)/g, '<a href="$2">$1</a>');
            value = value.replace(/\\*\\*([^*]+)\\*\\*/g, '<strong>$1</strong>');
            value = value.replace(/__([^_]+)__/g, '<strong>$1</strong>');
            value = value.replace(/(^|[^*])\\*([^*]+)\\*/g, '$1<em>$2</em>');
            value = value.replace(/(^|[^_])_([^_]+)_/g, '$1<em>$2</em>');
            return value.replace(/~~([^~]+)~~/g, '<del>$1</del>');
        }

        function parse(markdown) {
            const lines = markdown.replace(/\\r\\n/g, '\\n').split('\\n');
            const output = [];
            let index = 0;
            while (index < lines.length) {
                const line = lines[index].trim();
                if (!line) { index += 1; continue; }
                const fence = line.match(/^(`{3}|~{3})\\s*(.*)$/);
                if (fence) {
                    const marker = fence[1];
                    const code = [];
                    index += 1;
                    while (index < lines.length && lines[index].trim() !== marker) {
                        code.push(lines[index]);
                        index += 1;
                    }
                    if (index < lines.length) { index += 1; }
                    output.push('<pre' + (fence[2] ? ' data-language="' + esc(fence[2]) + '"' : '') + '><code>' + esc(code.join('\\n')) + '</code></pre>');
                    continue;
                }
                const heading = line.match(/^(#{1,6})\\s+(.+)$/);
                if (heading) {
                    output.push('<h' + heading[1].length + '>' + inline(heading[2]) + '</h' + heading[1].length + '>');
                    index += 1;
                    continue;
                }
                if (/^([-*_])\\1\\1+$/.test(line)) { output.push('<hr>'); index += 1; continue; }
                const bullet = line.match(/^[-+*]\\s+(.+)$/);
                if (bullet) {
                    const items = [bullet[1]];
                    index += 1;
                    while (index < lines.length) {
                        const next = lines[index].trim().match(/^[-+*]\\s+(.+)$/);
                        if (!next) { break; }
                        items.push(next[1]);
                        index += 1;
                    }
                    output.push('<ul>' + items.map(item => '<li>' + inline(item) + '</li>').join('') + '</ul>');
                    continue;
                }
                const ordered = line.match(/^(\\d+)[.)]\\s+(.+)$/);
                if (ordered) {
                    const items = [[ordered[1], ordered[2]]];
                    index += 1;
                    while (index < lines.length) {
                        const next = lines[index].trim().match(/^(\\d+)[.)]\\s+(.+)$/);
                        if (!next) { break; }
                        items.push([next[1], next[2]]);
                        index += 1;
                    }
                    output.push('<ol start="' + ordered[1] + '">' + items.map(item => '<li>' + inline(item[1]) + '</li>').join('') + '</ol>');
                    continue;
                }
                if (line.startsWith('>')) {
                    const quoted = [line.slice(1).trim()];
                    index += 1;
                    while (index < lines.length && lines[index].trim().startsWith('>')) {
                        quoted.push(lines[index].trim().slice(1).trim());
                        index += 1;
                    }
                    output.push('<blockquote>' + quoted.map(item => inline(item)).join('<br>') + '</blockquote>');
                    continue;
                }
                const paragraph = [];
                while (index < lines.length && lines[index].trim() && !isBlockStart(lines[index].trim())) {
                    paragraph.push(lines[index].trim());
                    index += 1;
                }
                output.push('<p>' + inline(paragraph.join(' ')) + '</p>');
            }
            return output.join('');
        }

        function isBlockStart(line) {
            return /^(`{3}|~{3})/.test(line) || /^(#{1,6})\\s+/.test(line)
                || /^([-*_])\\1\\1+$/.test(line) || /^[-+*]\\s+/.test(line)
                || /^\\d+[.)]\\s+/.test(line) || line.startsWith('>');
        }

        function plain(text, canonical) {
            if (!canonical) { return text; }
            return Array.from(text).map(character =>
                '`*_[]~'.includes(character) ? String.fromCharCode(92) + character : character
            ).join('');
        }

        function inlineMarkdown(node, canonical) {
            if (node.nodeType === Node.TEXT_NODE) { return plain(node.nodeValue, canonical); }
            if (node.tagName === 'BR') { return '\\n'; }
            const content = Array.from(node.childNodes).map(child => inlineMarkdown(child, canonical)).join('');
            switch (node.tagName) {
                case 'STRONG': case 'B': return '**' + content + '**';
                case 'EM': case 'I': return '*' + content + '*';
                case 'DEL': case 'S': case 'STRIKE': return '~~' + content + '~~';
                case 'CODE': {
                    const fence = node.textContent.includes('`') ? '``' : '`';
                    return fence + node.textContent + fence;
                }
                case 'A': return '[' + content + '](' + node.getAttribute('href') + ')';
                default: return content;
            }
        }

        function blockMarkdown(node, canonical) {
            switch (node.tagName) {
                case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6':
                    return '#'.repeat(Number(node.tagName.slice(1))) + ' ' + inlineMarkdown(node, canonical);
                case 'UL':
                    return Array.from(node.children).filter(child => child.tagName === 'LI')
                        .map(child => '- ' + inlineMarkdown(child, canonical)).join('\\n');
                case 'OL': {
                    const start = Number(node.getAttribute('start') || 1);
                    return Array.from(node.children).filter(child => child.tagName === 'LI')
                        .map((child, index) => String(start + index) + '. ' + inlineMarkdown(child, canonical)).join('\\n');
                }
                case 'BLOCKQUOTE':
                    return '> ' + inlineMarkdown(node, canonical).replace(/\\n/g, '\\n> ');
                case 'PRE':
                    return '```' + (node.getAttribute('data-language') || '') + '\\n' + node.textContent + '\\n```';
                case 'HR': return '---';
                default: return inlineMarkdown(node, canonical);
            }
        }

        function getMarkdown(canonical = true) {
            return Array.from(editor.childNodes).map(node => {
                if (node.nodeType === Node.TEXT_NODE) { return plain(node.nodeValue, canonical); }
                return blockMarkdown(node, canonical);
            }).filter(part => part.trim().length > 0).join('\\n\\n');
        }

        function caretOffset() {
            const selection = window.getSelection();
            if (!selection.rangeCount) { return null; }
            const range = selection.getRangeAt(0);
            const preceding = range.cloneRange();
            preceding.selectNodeContents(editor);
            preceding.setEnd(range.startContainer, range.startOffset);
            return preceding.toString().length;
        }

        function setCaret(offset) {
            if (offset === null) { return; }
            const selection = window.getSelection();
            const range = document.createRange();
            let remaining = offset;
            function visit(node) {
                if (node.nodeType === Node.TEXT_NODE) {
                    const length = node.nodeValue.length;
                    if (remaining <= length) {
                        range.setStart(node, remaining);
                        range.collapse(true);
                        selection.removeAllRanges();
                        selection.addRange(range);
                        return true;
                    }
                    remaining -= length;
                }
                for (const child of node.childNodes) {
                    if (visit(child)) { return true; }
                }
                return false;
            }
            if (!visit(editor)) {
                range.selectNodeContents(editor);
                range.collapse(false);
                selection.removeAllRanges();
                selection.addRange(range);
            }
        }

        function render(markdown) {
            const shouldRestoreFocus = document.activeElement === editor;
            const offset = caretOffset();
            editor.innerHTML = parse(markdown);
            if (shouldRestoreFocus) { editor.focus({ preventScroll: true }); }
            setCaret(offset);
        }

        function setMarkdown(markdown) { render(markdown); }

        function notify() {
            if (window.webkit && window.webkit.messageHandlers.markdownChanged) {
                window.webkit.messageHandlers.markdownChanged.postMessage(getMarkdown(true));
            }
        }

        function captureCaret() {
            const selection = window.getSelection();
            if (!selection.rangeCount) { return null; }
            const range = selection.getRangeAt(0);
            if (!editor.contains(range.startContainer)) { return null; }
            const point = range.cloneRange();
            point.collapse(true);
            if (range.startContainer.nodeType !== Node.TEXT_NODE) {
                const container = range.startContainer;
                if (range.startOffset < container.childNodes.length) {
                    point.selectNodeContents(container.childNodes[range.startOffset]);
                    point.collapse(true);
                } else {
                    point.selectNodeContents(container);
                    point.collapse(false);
                }
            }
            return { node: point.startContainer, offset: point.startOffset, fallback: caretOffset() };
        }

        function restoreCaret(caret) {
            if (!caret) { return; }
            if (caret.node.isConnected && editor.contains(caret.node)) {
                const range = document.createRange();
                let container = caret.node;
                let offset = caret.offset;
                if (container.nodeType === Node.TEXT_NODE && !container.nodeValue.length && container.parentNode) {
                    offset = Array.prototype.indexOf.call(container.parentNode.childNodes, container);
                    container = container.parentNode;
                }
                const length = container.nodeType === Node.TEXT_NODE
                    ? container.nodeValue.length : container.childNodes.length;
                range.setStart(container, Math.min(offset, length));
                range.collapse(true);
                const selection = window.getSelection();
                selection.removeAllRanges();
                selection.addRange(range);
                const command = { strong: 'bold', em: 'italic', del: 'strikeThrough' }[caret.exitInline];
                if (command && document.queryCommandState(command)) {
                    document.execCommand(command, false, false);
                }
            } else {
                setCaret(caret.fallback);
            }
        }

        function scheduleNormalize() {
            clearTimeout(normalizeTimer);
            normalizeTimer = setTimeout(normalizeEditor, 240);
        }

        function textNodes(root) {
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            const nodes = [];
            while (walker.nextNode()) { nodes.push(walker.currentNode); }
            return nodes;
        }

        function replaceTextSegment(node, start, length, content, tag, url, caret) {
            const source = node.nodeValue;
            const after = document.createTextNode(source.slice(start + length));
            const element = document.createElement(tag);
            element.textContent = content;
            if (url) { element.href = url; }
            if (caret && caret.node === node) {
                if (caret.offset >= start + length) {
                    caret.node = after;
                    caret.offset -= start + length;
                    caret.exitInline = tag;
                } else if (caret.offset >= start) {
                    caret.node = element.firstChild;
                    caret.offset = Math.min(content.length, caret.offset - start);
                }
            }
            node.nodeValue = source.slice(0, start);
            node.parentNode.insertBefore(element, node.nextSibling);
            node.parentNode.insertBefore(after, element.nextSibling);
        }

        function formatInlineElements(caret) {
            const rules = [
                { regex: /`([^`\\n]+)`/, tag: 'code' },
                { regex: /\\[([^\\]]+)\\]\\((https?:\\/\\/[^\\s)]+)\\)/, tag: 'a', url: true },
                { regex: /\\*\\*([^*]+)\\*\\*/, tag: 'strong' },
                { regex: /__([^_]+)__/, tag: 'strong' },
                { regex: /~~([^~]+)~~/, tag: 'del' },
                { regex: /(^|[^*])\\*([^*]+)\\*/, tag: 'em', prefix: true },
                { regex: /(^|[^_])_([^_]+)_/, tag: 'em', prefix: true }
            ];
            for (const node of textNodes(editor)) {
                if (['CODE', 'PRE', 'A'].includes(node.parentElement.tagName)) { continue; }
                for (const rule of rules) {
                    while (true) {
                        const match = rule.regex.exec(node.nodeValue);
                        if (!match) { break; }
                        const prefix = rule.prefix ? match[1].length : 0;
                        replaceTextSegment(node, match.index + prefix, match[0].length - prefix,
                            rule.prefix ? match[2] : match[1], rule.tag, rule.url ? match[2] : null, caret);
                    }
                }
            }
        }

        function replaceBlock(block, tag, prefixLength, start, caret) {
            const replacement = document.createElement(tag);
            if (tag === 'ol') { replacement.setAttribute('start', String(start)); }
            const container = tag === 'ul' || tag === 'ol' ? document.createElement('li') : replacement;
            if (container !== replacement) { replacement.appendChild(container); }
            while (block.firstChild) {
                const child = block.firstChild;
                if (child.nodeType === Node.TEXT_NODE && child.nodeValue.trim().length > 0 && prefixLength > 0) {
                    const removed = Math.min(prefixLength, child.nodeValue.length);
                    child.nodeValue = child.nodeValue.slice(removed);
                    if (caret && caret.node === child) { caret.offset = Math.max(0, caret.offset - removed); }
                    prefixLength -= removed;
                }
                container.appendChild(child);
            }
            block.replaceWith(replacement);
        }

        function replaceWithCode(block, match, caret) {
            const content = match[2].replace(/\\n$/, '');
            const pre = document.createElement('pre');
            const code = document.createElement('code');
            const text = document.createTextNode(content);
            if (match[1]) { pre.dataset.language = match[1]; }
            if (caret && block.contains(caret.node)) {
                const preceding = document.createRange();
                preceding.selectNodeContents(block);
                preceding.setEnd(caret.node, caret.offset);
                caret.node = text;
                caret.offset = Math.min(content.length,
                    Math.max(0, preceding.toString().length - match[0].indexOf('\\n') - 1));
            }
            code.appendChild(text);
            pre.appendChild(code);
            block.replaceWith(pre);
        }

        function replaceWithRule(block, caret) {
            const rule = document.createElement('hr');
            if (caret && block.contains(caret.node)) {
                const paragraph = document.createElement('p');
                const text = document.createTextNode('');
                paragraph.appendChild(text);
                paragraph.appendChild(document.createElement('br'));
                block.replaceWith(rule, paragraph);
                caret.node = text;
                caret.offset = 0;
            } else {
                block.replaceWith(rule);
            }
        }

        function formatBlocks(caret) {
            for (const block of Array.from(editor.children)) {
                const tag = block.tagName;
                if (tag === 'PRE' || tag === 'CODE') { continue; }
                const source = blockMarkdown(block, false);
                const code = source.match(/^```([^\\n]*)\\n([\\s\\S]*)```$/);
                if (code && (tag === 'P' || tag === 'DIV')) {
                    replaceWithCode(block, code, caret);
                    continue;
                }
                const text = block.textContent;
                const heading = text.match(/^(#{1,6})\\s+/);
                if (heading && (tag === 'P' || tag === 'DIV')) {
                    replaceBlock(block, 'h' + heading[1].length, heading[0].length, 0, caret);
                    continue;
                }
                if ((tag === 'P' || tag === 'DIV') && /^([-*_])\\1\\1+$/.test(text.trim())) {
                    replaceWithRule(block, caret);
                    continue;
                }
                if ((tag === 'P' || tag === 'DIV') && /^[-+*]\\s+/.test(text)) {
                    replaceBlock(block, 'ul', 2, 0, caret);
                    continue;
                }
                const ordered = text.match(/^(\\d+)[.)]\\s+/);
                if (ordered && (tag === 'P' || tag === 'DIV')) {
                    replaceBlock(block, 'ol', ordered[0].length, Number(ordered[1]), caret);
                    continue;
                }
                if ((tag === 'P' || tag === 'DIV') && /^>\\s?/.test(text)) {
                    replaceBlock(block, 'blockquote', text.startsWith('> ') ? 2 : 1, 0, caret);
                }
            }
        }

        function normalizeRootTextBlocks(caret) {
            for (const node of textNodes(editor)) {
                if (node.parentElement !== editor) { continue; }
                const value = node.nodeValue;
                const code = value.match(/^```([^\\n]*)\\n([\\s\\S]*)```$/);
                if (code) {
                    replaceWithCode(node, code, caret);
                    continue;
                }
                if (!value.includes('\\n') && !/^(#{1,6}\\s|[-+*]\\s|\\d+[.)]\\s|>|```)/.test(value)) { continue; }
                const fragment = document.createDocumentFragment();
                let lineStart = 0;
                for (const line of value.split('\\n')) {
                    const paragraph = document.createElement('p');
                    const text = document.createTextNode(line);
                    if (caret && caret.node === node && caret.offset >= lineStart
                        && caret.offset <= lineStart + line.length) {
                        caret.node = text;
                        caret.offset -= lineStart;
                    }
                    paragraph.appendChild(text);
                    if (!line.length) { paragraph.appendChild(document.createElement('br')); }
                    fragment.appendChild(paragraph);
                    lineStart += line.length + 1;
                }
                node.replaceWith(fragment);
            }
            for (const block of Array.from(editor.children)) {
                if (['UL', 'OL', 'PRE', 'CODE'].includes(block.tagName)) { continue; }
                const source = blockMarkdown(block, false);
                const code = source.match(/^```([^\\n]*)\\n([\\s\\S]*)```$/);
                if (code) {
                    replaceWithCode(block, code, caret);
                    continue;
                }
                if (!block.querySelector('br')) { continue; }
                const pieces = [document.createElement(block.tagName)];
                for (const child of Array.from(block.childNodes)) {
                    if (child.tagName === 'BR') {
                        const paragraph = document.createElement('p');
                        const text = document.createTextNode('');
                        paragraph.appendChild(text);
                        if (caret && caret.node === child) {
                            caret.node = text;
                            caret.offset = 0;
                        }
                        pieces.push(paragraph);
                    } else {
                        pieces[pieces.length - 1].appendChild(child);
                    }
                }
                block.replaceWith(...pieces);
            }
        }

        function normalizeEditor() {
            if (composing) { return; }
            clearTimeout(normalizeTimer);
            const caret = captureCaret();
            normalizeRootTextBlocks(caret);
            formatInlineElements(caret);
            formatBlocks(caret);
            notify();
            restoreCaret(caret);
        }

        function flushEditor() {
            clearTimeout(normalizeTimer);
            if (composing) { notify(); }
            else { normalizeEditor(); }
        }

        function focusEditor() {
            editor.focus({ preventScroll: true });
            if (!editor.textContent.length) { setCaret(0); }
        }

        editor.addEventListener('input', event => {
            if (composing || event.isComposing) {
                clearTimeout(normalizeTimer);
                return;
            }
            scheduleNormalize();
        });
        editor.addEventListener('compositionstart', () => {
            composing = true;
            clearTimeout(normalizeTimer);
        });
        editor.addEventListener('compositionend', () => {
            composing = false;
            scheduleNormalize();
        });
        editor.addEventListener('focus', () => {
            if (window.webkit && window.webkit.messageHandlers.focusChanged) {
                window.webkit.messageHandlers.focusChanged.postMessage(true);
            }
        });
        editor.addEventListener('blur', () => {
            flushEditor();
            if (window.webkit && window.webkit.messageHandlers.focusChanged) {
                window.webkit.messageHandlers.focusChanged.postMessage(false);
            }
        });
        editor.addEventListener('paste', event => {
            event.preventDefault();
            document.execCommand('insertText', false, event.clipboardData.getData('text/plain'));
        });
        editor.addEventListener('keydown', event => {
            if (event.key === 'Tab') {
                event.preventDefault();
                document.execCommand('insertText', false, '\\t');
            }
        });
        </script>
        </body>
        </html>
        """
    }

    static func javascriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(encoded.dropFirst().dropLast())
    }
}

@MainActor
final class MarkdownEditorCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Binding var text: String
    @Binding var isFocused: Bool
    private weak var webView: WKWebView?
    private var isReady = false
    private var lastMarkdown: String?
    private var requestedFocus: Bool
    private var lastFocus: Bool?
    private var lastStyle: String?
    private var fontSize: CGFloat = 12
    private var textColor = NSColor.labelColor

    init(text: Binding<String>, isFocused: Binding<Bool>) {
        _text = text
        _isFocused = isFocused
        requestedFocus = isFocused.wrappedValue
    }

    func attach(to webView: WKWebView, placeholder: String) {
        self.webView = webView
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "markdownChanged")
        webView.configuration.userContentController.add(self, name: "focusChanged")
        webView.loadHTMLString(MarkdownTextEditor.pageHTML(placeholder: placeholder), baseURL: nil)
    }

    func update(text: String, isFocused: Bool, fontSize: CGFloat, textColor: NSColor) {
        requestedFocus = isFocused
        self.fontSize = fontSize
        self.textColor = textColor
        guard isReady else { return }
        if lastMarkdown != text { setMarkdown(text) }
        updateStyle()
        updateFocus(isFocused)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "markdownChanged", let markdown = message.body as? String {
            lastMarkdown = markdown
            if text != markdown { text = markdown }
        } else if message.name == "focusChanged", let focused = message.body as? Bool {
            lastFocus = focused
            isFocused = focused
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        setMarkdown(text)
        updateStyle()
        updateFocus(requestedFocus)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else { return .allow }
        _ = NSWorkspace.shared.open(url)
        return .cancel
    }

    private func setMarkdown(_ markdown: String) {
        lastMarkdown = markdown
        webView?.evaluateJavaScript("setMarkdown(\(MarkdownTextEditor.javascriptString(markdown)))")
    }

    private func updateFocus(_ focused: Bool) {
        guard lastFocus != focused else { return }
        lastFocus = focused
        webView?.evaluateJavaScript(focused ? "focusEditor()" : "document.getElementById('editor').blur()")
        if focused {
            DispatchQueue.main.async { [weak self, weak webView] in
                self?.webView?.window?.makeFirstResponder(webView)
            }
        }
    }

    private func updateStyle() {
        let color = textColor.usingColorSpace(.sRGB) ?? textColor
        let style = "\(fontSize)|\(color.redComponent)|\(color.greenComponent)|\(color.blueComponent)|\(color.alphaComponent)"
        guard lastStyle != style else { return }
        lastStyle = style
        let red = Int(color.redComponent * 255)
        let green = Int(color.greenComponent * 255)
        let blue = Int(color.blueComponent * 255)
        webView?.evaluateJavaScript("""
            document.getElementById('editor').style.fontSize = '\(fontSize)px';
            document.getElementById('editor').style.color = 'rgba(\(red),\(green),\(blue),\(color.alphaComponent))';
        """)
    }
}
