import Combine
import Foundation
import SwiftUI

/// Raw values are stable preferences; display names remain recognizable in either UI language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var nativeName: String { self == .english ? "English" : "简体中文" }
    var locale: Locale { Locale(identifier: self == .english ? "en_US" : "zh_CN") }

    static func resolve(saved: String?, preferredLanguages: [String]) -> AppLanguage {
        if let saved, let language = AppLanguage(rawValue: saved) { return language }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .simplifiedChinese : .english
    }
}

/// UI preferences never change task content, stored dates, or task ordering identifiers.
final class LanguageSettings: ObservableObject {
    static let defaultsKey = "interfaceLanguage"
    static let shared = LanguageSettings()
    static let didChange = Notification.Name("ToccataInterfaceLanguageDidChange")

    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            defaults.set(language.rawValue, forKey: Self.defaultsKey)
            L10n.language = language
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }
    private let defaults: UserDefaults
    @Published private(set) var contentOpacity = 1.0
    private var transitionTask: Task<Void, Never>?

    /// Fade the existing view hierarchy instead of replacing it with a language ID.
    /// This preserves selections, scroll positions, and in-progress editor drafts.
    @MainActor
    func select(_ next: AppLanguage, reduceMotion: Bool) {
        transitionTask?.cancel()
        transitionTask = nil
        guard next != language, !reduceMotion else {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                contentOpacity = 1
            }
            if next != language { language = next }
            return
        }

        withAnimation(.easeOut(duration: 0.1)) { contentOpacity = 0 }
        transitionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return }
            guard let self, !Task.isCancelled else { return }

            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { self.language = next }

            // Let localized AppKit controls settle before the reveal animation;
            // their width changes should not inherit a layout animation.
            do { try await Task.sleep(nanoseconds: 20_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.16)) { self.contentOpacity = 1 }
            self.transitionTask = nil
        }
    }

    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        language = AppLanguage.resolve(saved: defaults.string(forKey: Self.defaultsKey),
                                       preferredLanguages: preferredLanguages)
        L10n.language = language
    }
}

private struct LanguageChangeTransition: ViewModifier {
    @ObservedObject private var settings = LanguageSettings.shared

    func body(content: Content) -> some View {
        content.opacity(settings.contentOpacity)
    }
}

extension View {
    /// Apply once per window/panel, never to individual rows or nested editors.
    func languageChangeTransition() -> some View {
        modifier(LanguageChangeTransition())
    }
}

/// Literal templates and interpolated values are kept separate. User text is never
/// looked up as a translation key, even if it happens to match an interface label.
struct LocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]

    init(stringLiteral value: String) { key = value; arguments = [] }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }
}

enum L10n {
    private static let lock = NSLock()
    private static var selectedLanguage = AppLanguage.resolve(
        saved: UserDefaults.standard.string(forKey: LanguageSettings.defaultsKey),
        preferredLanguages: Locale.preferredLanguages)
    static var language: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return selectedLanguage }
        set { lock.lock(); defer { lock.unlock() }; selectedLanguage = newValue }
    }
    static var locale: Locale { language.locale }
    static let english: [String: String] = {
        guard let data = ResourceLoader.jsonData(named: "English", subdirectory: "Localization"),
              let catalog = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return catalog
    }()
    private static let placeholder = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    static func tr(_ text: LocalizedText) -> String {
        render(key: text.key, arguments: text.arguments, language: language)
    }

    /// For stable, non-user-authored enum labels only. Never pass task titles here.
    static func key(_ key: String) -> String { render(key: key, arguments: [], language: language) }

    static func render(key: String, arguments: [String], language: AppLanguage) -> String {
        let template = language == .english ? (english[key] ?? key) : key
        let source = template as NSString
        var result = "", start = 0
        for match in placeholder.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: start, length: match.range.location - start))
            let index = Int(source.substring(with: match.range(at: 1)))!
            result += arguments.indices.contains(index) ? arguments[index] : source.substring(with: match.range)
            start = NSMaxRange(match.range)
        }
        result += source.substring(from: start)
        return result
    }

    static func monthTitle(_ date: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle.dateTime.year().month(.wide).locale(locale)
        style.calendar = calendar
        return date.formatted(style)
    }
    static func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        return formatter.shortMonthSymbols[max(0, min(month - 1, 11))]
    }
    static func date(_ date: Date, full: Bool = false) -> String {
        if full { return date.formatted(.dateTime.year().month(.wide).day().weekday(.wide).locale(locale)) }
        return date.formatted(.dateTime.month().day().locale(locale))
    }
}
