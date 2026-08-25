# Releasing Window Columns

Window Columns uses Semantic Versioning. During the public beta, release tags
use the form `v0.x.y-beta.n`. The exact tag without its leading `v` lives in
`VERSION`.

macOS requires `CFBundleShortVersionString` to remain numeric, so both app
property lists contain the numeric base version, while `CFBundleGetInfoString`,
`VERSION`, the changelog, and the Git tag identify the beta prerelease.
`CFBundleVersion` is an independently increasing build number.

## Release checklist

1. Update `VERSION`, both property lists, and `CHANGELOG.md`.
2. Increase `CFBundleVersion` in both property lists.
3. Run `make verify`.
4. For activation, layout, or companion changes, install the app and run
   `make test-runtime`.
5. Confirm `git diff --check` is clean and review every tracked file.
6. Commit the release, then create an annotated tag matching `VERSION`:

   ```sh
   version="$(tr -d '[:space:]' < VERSION)"
   git tag -a "v$version" -m "Window Columns $version"
   git push origin main "v$version"
   ```

7. Create a GitHub prerelease from the tag. Use the matching changelog section
   as release notes and keep **Set as a pre-release** enabled.

## Binary distribution during beta

A beta `.app` bundle may be attached only when all of the following are true:

- it is freshly built from the tagged commit with `CONFIGURATION=release`;
- its bundle version matches `VERSION` and its nested signatures verify;
- it is zipped with macOS metadata preserved and has an attached SHA-256 file;
- the release is marked as a prerelease; and
- the release notes clearly state that it is ad-hoc signed, unnotarised, and may
  be blocked by Gatekeeper.

Replace this process with Developer ID signing and notarisation before calling a
binary release stable.
