import Foundation
import Darwin

/// Removes the `com.apple.quarantine` extended attribute from the application
/// bundle and its nested companion helper bundles.
///
/// When an unnotarised app is downloaded via a browser or archive utility,
/// macOS sets `com.apple.quarantine` on the bundle and its contents. Gatekeeper
/// evaluates this attribute on launch. Once the user opens the application
/// (e.g. via Homebrew cask postflight, terminal, or System Settings "Open Anyway"),
/// removing any remaining quarantine attributes ensures that:
/// 1. Nested companion helpers (`Window Group 1..9.app`) are never blocked when spawned.
/// 2. Future launches of the application run without Gatekeeper interference.
enum QuarantineRemover {
    private static let quarantineAttribute = "com.apple.quarantine"

    /// Strips quarantine attribute from a single file or directory if present.
    @discardableResult
    static func stripQuarantine(at url: URL) -> Bool {
        let path = url.path
        let result = removexattr(path, quarantineAttribute, XATTR_NOFOLLOW)
        return result == 0
    }

    /// Recursively strips quarantine attributes from a bundle and all of its contents.
    static func stripQuarantineRecursively(at rootURL: URL) {
        let fm = FileManager.default
        stripQuarantine(at: rootURL)

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            stripQuarantine(at: fileURL)
        }
    }

    /// Cleans quarantine attributes from the main app bundle and all nested
    /// companion helper applications under `Contents/Helpers/`.
    static func cleanSelfAndHelpers() {
        let mainBundleURL = Bundle.main.bundleURL
        guard mainBundleURL.pathExtension == "app" else { return }

        // Clean main bundle and nested items
        stripQuarantineRecursively(at: mainBundleURL)

        // Specifically ensure the Helpers directory is thoroughly cleared
        let helpersURL = mainBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)

        if FileManager.default.fileExists(atPath: helpersURL.path) {
            stripQuarantineRecursively(at: helpersURL)
        }
    }
}
