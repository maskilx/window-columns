# Changelog

All notable changes to Window Columns are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the project is in beta, compatibility may change between minor releases.

## [Unreleased]

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

[Unreleased]: https://github.com/maskilx/window-columns/compare/v0.1.0-beta.3...HEAD
[0.1.0-beta.3]: https://github.com/maskilx/window-columns/compare/v0.1.0-beta.2...v0.1.0-beta.3
[0.1.0-beta.2]: https://github.com/maskilx/window-columns/compare/v0.1.0-beta.1...v0.1.0-beta.2
[0.1.0-beta.1]: https://github.com/maskilx/window-columns/releases/tag/v0.1.0-beta.1
