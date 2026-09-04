import AppKit
import Foundation
import WindowColumnsCore

struct UpdateInfo: Equatable {
    let version: SemanticVersion
    let versionString: String
    let releaseTitle: String
    let releaseNotes: String
    let releaseURL: URL
    let downloadURL: URL?
    let publishedAt: Date?
    let isPrerelease: Bool
}

@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published private(set) var isChecking = false
    @Published private(set) var availableUpdate: UpdateInfo?

    private let releasesAPIURL = URL(string: "https://api.github.com/repos/maskilx/window-columns/releases?per_page=10")!
    private let releasesWebURL = URL(string: "https://github.com/maskilx/window-columns/releases")!

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlUrl: String
        let prerelease: Bool
        let draft: Bool
        let publishedAt: String?
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlUrl = "html_url"
            case prerelease
            case draft
            case publishedAt = "published_at"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadUrl: String
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
            case size
        }
    }

    func checkForUpdates(store: LayoutStore, interactive: Bool) {
        guard !isChecking else { return }
        isChecking = true

        Task { @MainActor in
            defer { isChecking = false }
            do {
                var request = URLRequest(url: releasesAPIURL)
                request.setValue("WindowColumns", forHTTPHeaderField: "User-Agent")
                request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 15

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }

                if httpResponse.statusCode != 200 {
                    let msg = httpResponse.statusCode == 403
                        ? "GitHub API rate limit reached. Please check back later or visit the GitHub releases page."
                        : "Server returned status code \(httpResponse.statusCode)."
                    throw NSError(domain: "WindowColumnsUpdate", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
                }

                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
                let publishedReleases = releases.filter { !$0.draft }

                // Find candidate release with the highest semantic version
                var highestCandidate: (release: GitHubRelease, semver: SemanticVersion)?
                for release in publishedReleases {
                    guard let semver = SemanticVersion(string: release.tagName) else { continue }
                    if let currentHighest = highestCandidate {
                        if semver > currentHighest.semver {
                            highestCandidate = (release, semver)
                        }
                    } else {
                        highestCandidate = (release, semver)
                    }
                }

                store.preferences.lastUpdateCheckDate = Date()

                guard let (latestRelease, latestSemver) = highestCandidate else {
                    if interactive {
                        showUpToDateAlert(currentVersion: AppVersion.current)
                    }
                    return
                }

                let currentSemver = AppVersion.semantic
                if latestSemver > currentSemver {
                    // Look for an arm64 zip asset or general zip asset
                    let downloadURL: URL? = {
                        if let asset = latestRelease.assets.first(where: { $0.name.hasSuffix("-macos-arm64.zip") })
                            ?? latestRelease.assets.first(where: { $0.name.hasSuffix(".zip") }) {
                            return URL(string: asset.browserDownloadUrl)
                        }
                        return nil
                    }()

                    let releasePageURL = URL(string: latestRelease.htmlUrl) ?? releasesWebURL
                    let dateFormatter = ISO8601DateFormatter()
                    let publishedDate = latestRelease.publishedAt.flatMap { dateFormatter.date(from: $0) }

                    let info = UpdateInfo(
                        version: latestSemver,
                        versionString: latestRelease.tagName.hasPrefix("v") ? String(latestRelease.tagName.dropFirst()) : latestRelease.tagName,
                        releaseTitle: latestRelease.name ?? latestRelease.tagName,
                        releaseNotes: latestRelease.body ?? "",
                        releaseURL: releasePageURL,
                        downloadURL: downloadURL,
                        publishedAt: publishedDate,
                        isPrerelease: latestRelease.prerelease
                    )

                    self.availableUpdate = info
                    UpdateWindow.present(update: info, currentVersion: AppVersion.current)
                } else {
                    self.availableUpdate = nil
                    if interactive {
                        showUpToDateAlert(currentVersion: AppVersion.current)
                    }
                }
            } catch {
                if interactive {
                    showErrorAlert(error: error)
                }
            }
        }
    }

    private func showUpToDateAlert(currentVersion: String) {
        WindowActivator.activateSelf()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "You’re up to date!"
        alert.informativeText = "Window Columns \(currentVersion) is currently the newest version available."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showErrorAlert(error: Error) {
        WindowActivator.activateSelf()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update Check Failed"
        alert.informativeText = "Window Columns could not check for updates:\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        let githubButton = alert.addButton(withTitle: "View Releases on GitHub")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn || (response != .alertFirstButtonReturn && alert.buttons.firstIndex(of: githubButton) == 1) {
            NSWorkspace.shared.open(releasesWebURL)
        }
    }
}
