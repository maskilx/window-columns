import Foundation

public enum AppVersion {
    /// The source-of-truth current version of the application.
    /// This is kept synchronized with the repository's `VERSION` file by `verify-release-metadata.sh`.
    public static let current = "0.1.0-beta.3"

    /// The parsed semantic version representation of the current app.
    public static var semantic: SemanticVersion {
        SemanticVersion(string: current)!
    }
}
