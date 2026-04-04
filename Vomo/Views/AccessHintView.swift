import SwiftUI

struct AccessHintView: View {
    let event: FileAccessLogger.AccessEvent
    @State private var showDetail = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: event.category.icon)
                .foregroundStyle(event.category.color)
                .font(.caption)
            Text(event.category.verb + " " + event.summary)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .onTapGesture {
            if event.detail != nil {
                showDetail.toggle()
            }
        }
        .popover(isPresented: $showDetail) {
            if let detail = event.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
                    .presentationCompactAdaptation(.popover)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if value.translation.height < -10 {
                        withAnimation(.easeOut(duration: 0.2)) {
                            FileAccessLogger.shared.currentHint = nil
                        }
                    }
                }
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
