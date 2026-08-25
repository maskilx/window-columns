# Privacy

Window Columns is designed to work entirely on your Mac.

## Data the app accesses

With macOS Accessibility permission, the app reads the applications and windows
currently available to your user account, including application identifiers,
window titles, window numbers, positions, sizes, and minimized state. It uses
that access to arrange and focus only the windows you place in a group.

If window previews are enabled and you grant Screen Recording permission, the
app captures thumbnails for the chooser. Preview images are kept in memory for
display and are not written to disk by Window Columns.

## Data stored locally

The app stores preferences, saved layouts, and group definitions in macOS
`UserDefaults` under the bundle identifier `com.adimaskil.WindowColumns`. Group
definitions can contain application identifiers, window titles, window numbers,
display identifiers, layout ratios, names, and timestamps.

The local signing helper can create a code-signing identity named
`Window Columns Local Signing` in your login keychain. It is used only to keep
the app's Accessibility identity stable across local rebuilds.

## Network and analytics

The application contains no analytics, advertising, telemetry, update service,
or application-level network client. It does not transmit window metadata,
previews, preferences, or saved groups.

GitHub is involved only when you independently visit this repository or use
GitHub features; GitHub's own privacy terms then apply.

## Removing local data

Quit the app, remove `Window Columns.app`, and run:

```sh
defaults delete com.adimaskil.WindowColumns
```

You can revoke Accessibility and Screen Recording access in **System Settings →
Privacy & Security**. If you created the optional local signing identity, you
can remove it separately with Keychain Access.

## Changes

Privacy-impacting changes will be documented in `CHANGELOG.md` and reflected in
this file before release.
