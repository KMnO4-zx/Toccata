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
    let title: String
    let totalCount: Int
    let counts: [Int: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer(minLength: 12)
                Text("\(totalCount.formatted()) 次")
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
        Text("悬停查看按键次数 · Fn 显示按住时长")
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
                    Text("常用按键").foregroundStyle(.secondary)
                    ForEach(entries) { entry in keyUsage(entry) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("常用按键").foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(entries) { entry in keyUsage(entry) }
                    }
                }
            }
            .font(.system(size: 11))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("所选时段按键次数前五名")
            .accessibilityValue(entries.map { "\($0.name)，\($0.count) 次" }.joined(separator: "；"))
        }
    }

    private func keyUsage(_ entry: KeyboardUsageRanking.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.name)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
            Text("\(entry.count.formatted()) 次")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
