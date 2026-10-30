import SwiftUI

/// 两种原生列表共享布局，业务状态和执行仍由调用方管理。
struct NativeResultList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let selectedID: Item.ID?
    @ViewBuilder let row: (Item, Int) -> Row
    @State private var rowHeights: [Item.ID: CGFloat] = [:]

    var body: some View {
        ScrollViewReader { proxy in
            List { rows }
            .listStyle(.plain)
            .padding(.horizontal, -8) // 与 macOS List 保持一致
            .scrollContentBackground(.hidden)
            .contentMargins(0, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 52)
            .frame(height: visibleHeight)
            .onChange(of: selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onChange(of: items.map(\.id)) { _, _ in
                let identifiers = Set(items.map(\.id))
                rowHeights = rowHeights.filter { identifiers.contains($0.key) }
                if let selectedID { proxy.scrollTo(selectedID) }
            }
        }
    }

    private var visibleHeight: CGFloat {
        guard !items.isEmpty else { return 0 }
        // macOS List 的 contentSize 可能不小于视口；测量行高才能在结果减少时收缩。
        guard items.count < 8 else { return 444 }
        let height = items.reduce(CGFloat(0)) { $0 + (rowHeights[$1.id] ?? 52) }
        return min(ceil(height + CGFloat(items.count - 1) * 4), 444)
    }

    private var rows: some View {
        ForEach(items.enumerated(), id: \.element.id) { index, item in
            row(item, index)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    guard height.isFinite, height > 0, rowHeights[item.id] != height else { return }
                    rowHeights[item.id] = height
                }
                .padding(.bottom, index == items.count - 1 ? 0 : 4)
                // 清除系统行内边距，使实际行高与列表高度计算一致。
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .id(item.id)
        }
    }
}

struct NativeResultRow<Icon: View>: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let shortcut: String?
    let identifierPrefix: String
    let itemID: String
    let activate: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 12) {
                icon()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let subtitle, !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("\(identifierPrefix).subtitle.\(itemID)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let shortcut {
                    Text(shortcut).font(.caption).foregroundStyle(.secondary).fixedSize()
                        .accessibilityIdentifier("\(identifierPrefix).shortcut.\(itemID)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(NativeResultButtonStyle())
    }
}

private struct NativeResultButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // 查询时仍禁用执行，但不让整批结果因系统禁用样式而明暗闪动。
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}
