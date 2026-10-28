import SwiftUI

struct StripView: View {
    @ObservedObject var tracker: AppTracker
    @ObservedObject var previews: Previews
    @ObservedObject var settings: Settings
    let onLand: (StripApp) -> Void

    var body: some View {
        let horizontal = settings.edge.isHorizontal
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))

        ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
            layout {
                ForEach(tracker.apps) { app in
                    Tile(
                        app: app,
                        size: settings.size,
                        preview: settings.previews ? previews.images[app.pid] : nil,
                        landed: app.id == tracker.landed,
                        calling: tracker.calling.contains(app.id)
                    )
                    .onTapGesture { onLand(app) }
                    .contextMenu {
                        Button("Hide from Strip") { settings.hiddenApps.insert(app.id) }
                    }
                    .help(app.name)
                }
            }
            .padding(5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }
}

private struct Tile: View {
    let app: StripApp
    let size: StripSize
    let preview: NSImage?
    let landed: Bool
    let calling: Bool

    @State private var pulse = false

    var body: some View {
        content
            .padding(.horizontal, size == .icons ? 2 : 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(landed ? Color.accentColor.opacity(0.25) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.red, lineWidth: calling ? 2 : 0))
            .scaleEffect(pulse ? 1.08 : 1)
            .contentShape(Rectangle())
            .onChange(of: calling) { _, now in
                if now {
                    withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { pulse = true }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { pulse = false }
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch size {
        case .icons:
            icon(22).overlay(alignment: .topTrailing) { Badge(label: app.badge).offset(x: 6, y: -4) }
        case .names:
            HStack(spacing: 5) {
                icon(20).overlay(alignment: .topTrailing) { Badge(label: app.badge).offset(x: 6, y: -4) }
                Text(app.name).font(.system(size: 11)).lineLimit(1)
            }
            .frame(height: 24)
        case .large:
            VStack(spacing: 4) {
                Group {
                    if let preview {
                        Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        icon(44)
                    }
                }
                .frame(width: 150, height: 84)
                .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.08)))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                HStack(spacing: 4) {
                    icon(14)
                    Text(app.name).font(.system(size: 11)).lineLimit(1)
                    Spacer(minLength: 0)
                    Badge(label: app.badge)
                }
                .frame(width: 150)
            }
        }
    }

    private func icon(_ side: CGFloat) -> some View {
        Image(nsImage: app.icon).resizable().frame(width: side, height: side)
    }
}

private struct Badge: View {
    let label: String?

    var body: some View {
        if let label {
            if label == "•" {
                Circle().fill(.red).frame(width: 6, height: 6)
            } else {
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(.red))
            }
        }
    }
}
