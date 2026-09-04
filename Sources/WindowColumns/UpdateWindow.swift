import AppKit
import SwiftUI

@MainActor
enum UpdateWindow {
    private static var controller: NSWindowController?

    static func present(update: UpdateInfo, currentVersion: String) {
        if controller == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Software Update"
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
        }

        controller?.window?.contentView = NSHostingView(
            rootView: UpdateView(update: update, currentVersion: currentVersion, onDismiss: {
                controller?.close()
            })
        )
        WindowActivator.activateSelf()
        controller?.window?.makeKeyAndOrderFront(nil)
        controller?.window?.orderFrontRegardless()
    }
}

struct UpdateView: View {
    let update: UpdateInfo
    let currentVersion: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("A new version of Window Columns is available!")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Window Columns \(update.versionString) is now available (you have \(currentVersion)).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Release Notes")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(update.releaseNotes.isEmpty ? "No release notes provided." : update.releaseNotes)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxHeight: .infinity)
            }

            HStack {
                Text("Installed with Homebrew? Run: `brew upgrade window-columns`")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 12) {
                Button("View on GitHub") {
                    NSWorkspace.shared.open(update.releaseURL)
                }

                Spacer()

                Button("Later") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Download Update") {
                    let targetURL = update.downloadURL ?? update.releaseURL
                    NSWorkspace.shared.open(targetURL)
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
    }
}
