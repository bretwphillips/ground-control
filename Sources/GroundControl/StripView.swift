import SwiftUI

struct StripView: View {
    @ObservedObject var tracker: AppTracker
    @ObservedObject var settings: Settings
    let onLand: (StripApp) -> Void

    var body: some View {
        let horizontal = settings.edge.isHorizontal
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: 4))

        layout {
            ForEach(tracker.apps) { app in
                Tile(app: app, landed: app.id == tracker.landed, showName: horizontal)
                    .onTapGesture { onLand(app) }
                    .contextMenu {
                        Button("Hide from Strip") { settings.hiddenApps.insert(app.id) }
                    }
                    .help(app.name)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

private struct Tile: View {
    let app: StripApp
    let landed: Bool
    let showName: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 20, height: 20)
                .overlay(alignment: .topTrailing) { badge }
            if showName {
                Text(app.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, showName ? 6 : 2)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(landed ? Color.accentColor.opacity(0.25) : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var badge: some View {
        if let label = app.badge, !label.isEmpty {
            if label == "•" {
                Circle().fill(.red).frame(width: 6, height: 6).offset(x: 2, y: -2)
            } else {
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(.red))
                    .offset(x: 6, y: -4)
            }
        }
    }
}
