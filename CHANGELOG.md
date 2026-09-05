# Changelog

All notable changes to Window Columns are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the project is in beta, compatibility may change between minor releases.

## [Unreleased]

## [0.1.0-beta.4] - 2026-09-05

### Added

- Settings → General → Layout now offers screen-edge padding (0–64 pt), independently of column gaps, with persisted preferences and matching chooser previews.

### Fixed

- Minimize only the focused group when using the shortcut, preserve focus when minimizing a background group, and allow an ungrouped window from the same app to remain in front. Cancel delayed activation when focus moves to another window in the same app.

- Removed unconditional repeated raise/focus passes on Command-Tab, avoided reflowing an already arranged group, and ignored the resulting AX feedback to prevent activation shaking.

- Restore all sibling windows when activating a group containing multiple windows of the same app; select groups by the focused window and preserve its focus.
- Stop swallowing the first Command-Tab after creating a group, and allow Command-Tab to restore minimized groups after the brief macOS minimize cascade.
- Assign distinct WindowServer numbers to overlapping, identically titled windows and retain known identities when their titles or frames change.
- Cancel queued divider writes when the selection changes and serialize frame updates so obsolete resize work cannot overwrite a newer layout.
- Cancel delayed group raises when switching to another application, and prevent automatic activation from choosing another group during a restore.
- Preserve saved membership when an Accessibility scan temporarily misses a window; normalize duplicate group IDs and enforce the nine-group limit when loading saved groups.
- Serialize companion launches, reject stale launch completions, preserve crash retry backoff, and prevent relaunch during shutdown.
- Correct codesigning argument quoting for repository paths containing spaces.

### Tests

- Added coordinator activation regressions using simulated Codex windows, plus companion activation and launch-state checks.
- Isolated companion integration checks from user helpers and added actual window stacking and per-display geometry checks to the runtime suite.

## [0.1.0-beta.3] - 2026-09-04

### Added

- Native "Check for Updates" feature:
  - Queries GitHub Releases API directly for new beta and stable releases with zero third-party dependencies.
  - Built-in SemVer 2.0 parser and comparator supporting prerelease precedence ordering.
  - Interactive Software Update dialog displaying release notes, direct asset download, and Homebrew cask upgrade instructions.
  - Menu Bar context menu, Chooser gear menu, and Settings (General tab) update controls with automatic background checking.
- Menu Bar icon matching the application Dock icon:
  - Replaced wireframe window icon with the high-resolution, full-color application Dock icon.
  - Real-time appearance adaptation supporting Light and Dark modes with Retina sharpness.
- Gatekeeper resolution across distribution channels:
  - Added automatic `postflight` unquarantine hook to Homebrew Cask (`Casks/window-columns.rb`) to bypass Gatekeeper prompts on install.
  - Added in-app `QuarantineRemover` to automatically clear quarantine attributes from the application bundle and all 9 companion helper apps on launch.
  - Added Apple Hardened Runtime entitlements (`Resources/WindowColumns.entitlements`) and codesign support in `Scripts/build-app.sh`.
  - Added automated Apple Notary submission and stapling script (`Scripts/notarize.sh`).
  - Added `make unquarantine` target to `Makefile`.
  - Updated first-launch guidance in `README.md` for macOS Sequoia (15+).

### Changed

- Light Mode UI/UX polish across switcher components:
  - Redesigned Live Column Preview dock with appearance-adaptive translucent tray and high-contrast styling.
  - Replaced raw neon cyan text with a crisp macOS accent status pill (`Col 1: 50% · Col 2: 50%`).
  - Switched column cards to elevated `controlBackgroundColor` with subtle hairline strokes and shadows.
  - Upgraded interactive column divider handle with native macOS accent blue and animated hover feedback.
  - Modernized window cards, group shelves, and action buttons for seamless light and dark mode consistency.

## [0.1.0-beta.2] - 2026-09-04

### Added

- Redesigned Modern Window Switcher featuring frosted acrylic materials, display-aware fixed sizing tiers (Laptop vs. External Display), and stationary bounds without layout jitter.
- Interactive Live Column Preview dock supporting native drag-and-drop column reordering, quick shift chevrons, and interactive drag-to-resize divider split handles with live width percentages.
- Multi-group visual indicators showing color-coded group pills and group-tinted outlines across window cards.
- Free AI-powered group naming service utilizing Google Gemini 2.0 Flash REST API with intelligent offline heuristic fallback and approval review card.
- User settings configuration for Gemini API key with direct link to Google AI Studio.
- Classic design style toggle preserved as a fallback in Settings and Chooser menu.

### Fixed

- Fixed group minimization and Command-Tab companion restoration behavior.
- Automatically dismiss the window chooser when clicking outside on another application.
- Real-time card badge synchronization immediately reflecting group renames and deletions without requiring a window rescan.
- Background task cancellation safeguards on modal dismissal preventing orphaned network requests or memory retention.
- Sanitized window title strings against quotation marks, newlines, and prompt formatting issues.

## [0.1.0-beta.1] - 2026-08-25

### Added

- Initial public beta of the native macOS menu-bar application.
- Window groups with connected column resizing, snap-back, and column swapping.
- Per-group Dock and Command-Tab companions.
- Group minimization and restoration, keyboard shortcuts, saved layouts, undo,
  window previews, custom group names, appearance settings, and launch at login.
- Pure core checks, companion integration checks, runtime checks, and macOS CI.
- Public project policies, contribution guidance, issue forms, and release docs.

### Fixed

- Kept unrelated groups interactive when one or more other groups are minimized.

[Unreleased]: https://github.com/maskilx/window-columns/compare/v0.1.0-beta.4...HEAD
[0.1.0-beta.4]: https://github.com/maskilx/window-columns/compare/v0.1.0-beta.3...v0.1.0-beta.4
[0.1.0-beta.3]: https://github.com/maskilx/window-columns/compare/v0.1.0-beta.2...v0.1.0-beta.3
[0.1.0-beta.2]: https://github.com/maskilx/window-columns/compare/v0.1.0-beta.1...v0.1.0-beta.2
[0.1.0-beta.1]: https://github.com/maskilx/window-columns/releases/tag/v0.1.0-beta.1
