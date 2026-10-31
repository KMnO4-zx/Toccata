import SwiftUI

enum KeyboardUsageRanking {
    struct Entry: Identifiable, Equatable {
        let keycode: Int
        let name: String
        let count: Int
        var id: Int { keycode }
    }

    static func topFive(counts: [Int: Int], layout: KeyboardLayout = .magicKeyboard) -> [Entry] {
        counts.filter { $0.value > 0 }
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .prefix(5)
            .map { code, count in
                Entry(keycode: code,
                      name: layout.keys.first { $0.code == code }?.readableLabel ?? "Key\(code)",
                      count: count)
            }
    }
}

struct KeyboardActivityHeader: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    let title: String
    let totalCount: Int
    let counts: [Int: Int]

    var body: some View {
        let _ = interfaceLanguage.language
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer(minLength: 12)
                Text(L10n.tr("\(totalCount.formatted()) 次"))
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    hint
                    Spacer(minLength: 0)
                    topKeys
                }
                VStack(alignment: .leading, spacing: 12) {
                    hint
                    topKeys
                }
            }
        }
    }

    private var hint: some View {
        Text(L10n.tr("悬停查看次数与占比 · Fn 同时显示按住时长"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var topKeys: some View {
        let entries = KeyboardUsageRanking.topFive(counts: counts)
        if !entries.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(L10n.tr("常用按键")).foregroundStyle(.secondary)
                    ForEach(entries) { entry in keyUsage(entry) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("常用按键")).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(entries) { entry in gridKeyUsage(entry) }
                    }
                }
            }
            .font(.system(size: 11))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.tr("所选时段按键次数前五名"))
            .accessibilityValue(entries.map {
                L10n.tr("\($0.name)，\($0.count) 次") + "，" +
                    L10n.tr("占 \(Formatters.keyPercentage(count: $0.count, totalCount: totalCount))")
            }.joined(separator: "；"))
        }
    }

    private func keyUsage(_ entry: KeyboardUsageRanking.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            keyBadge(entry.name)
            keyStatistics(entry)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func gridKeyUsage(_ entry: KeyboardUsageRanking.Entry) -> some View {
        ViewThatFits(in: .horizontal) {
            keyUsage(entry)
            VStack(alignment: .leading, spacing: 4) {
                keyBadge(entry.name)
                keyStatistics(entry)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keyBadge(_ name: String) -> some View {
        Text(name)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    private func keyStatistics(_ entry: KeyboardUsageRanking.Entry) -> some View {
        Text(L10n.tr("\(entry.count.formatted()) 次") + " · " +
             Formatters.keyPercentage(count: entry.count, totalCount: totalCount))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}
