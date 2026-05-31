import SwiftUI

struct RichHistoryMenuView: View {
    let items: [RichHistoryItem]
    let selectionIndex: Int
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.caption.weight(.semibold))
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Text("↑/↓ to navigate, Enter to run")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(UIColor.systemGray6))

            if items.isEmpty {
                Text(isLoading ? "Loading shell history…" : "No shell history found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.systemBackground))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                HStack {
                                    Text(item.command)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(index == selectionIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                                .id(item.id)
                            }
                        }
                    }
                    .onAppear {
                        scrollToSelection(proxy: proxy)
                    }
                    .onChange(of: selectionIndex) { _, _ in
                        scrollToSelection(proxy: proxy)
                    }
                }
                .frame(maxHeight: 180)
                .background(Color(UIColor.systemBackground))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func scrollToSelection(proxy: ScrollViewProxy) {
        guard items.indices.contains(selectionIndex) else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(items[selectionIndex].id, anchor: .bottom)
        }
    }
}
