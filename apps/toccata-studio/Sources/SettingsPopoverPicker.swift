import SwiftUI

/// Settings and sidebar shortcuts share the same titled, checkmarked popover.
struct SettingsPopoverOptions<Option: Hashable>: View {
    let title: String
    let options: [Option]
    let selection: Option
    let optionTitle: (Option) -> String
    let onSelect: (Option) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(options, id: \.self) { option in
                Button { onSelect(option) } label: {
                    HStack {
                        Text(optionTitle(option))
                            .lineLimit(1)
                        Spacer(minLength: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .opacity(selection == option ? 1 : 0)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(selection == option ? Color.accentColor.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? [.isSelected] : [])
            }
        }
        .padding(10)
    }
}

struct SettingsPopoverPicker<Option: Hashable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let optionTitle: (Option) -> String
    let popoverWidth: CGFloat
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 12) {
                Text(optionTitle(selection))
                    .font(.system(size: 12))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            SettingsPopoverOptions(title: title, options: options, selection: selection,
                                   optionTitle: optionTitle) { option in
                isPresented = false
                selection = option
            }
            .frame(width: popoverWidth)
        }
        .accessibilityLabel(title)
        .accessibilityValue(optionTitle(selection))
    }
}
