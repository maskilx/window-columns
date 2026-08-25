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

## Distribution policy during beta

Publish source archives only. Do not attach a `.app` bundle until it has a
Developer ID signature, notarisation, a documented update path, and verification
on the supported macOS range.
