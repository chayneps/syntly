import SwiftUI
import AppKit

public struct AboutView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            // App Icon
            appIconView
                .frame(width: 80, height: 80)
                .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)

            // App Name & Version
            VStack(spacing: 4) {
                Text("Synt(ax)ly")
                    .font(.title2.bold())

                Text("Version 2.0.0 (v2)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text("Universal 2")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)

                    Text("macOS 14+")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }

            // Description
            Text("Lightweight, native real-time AI writing assistant for macOS. Instant local corrections and multi-tone custom persona rewrites.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Divider()
                .padding(.horizontal, 20)

            // Action Links
            HStack(spacing: 12) {
                Button {
                    if let url = URL(string: "https://github.com/chayneps/syntly") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("GitHub", systemImage: "link")
                }
                .controlSize(.regular)

                Button {
                    if let url = URL(string: "https://github.com/chayneps/syntly/issues") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Issues", systemImage: "ladybug")
                }
                .controlSize(.regular)
            }

            // Legal & Copyright
            VStack(spacing: 2) {
                Text("Copyright © 2026 Chay Nep")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Text("Released under the MIT License")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .frame(width: 340, height: 360)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var appIconView: some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if let path = Bundle.main.url(forResource: "app_icon_1024", withExtension: "png"),
                  let img = NSImage(contentsOf: path) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}
