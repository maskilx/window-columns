# Contributing to Window Columns

Thanks for helping improve Window Columns. The project is currently a public
beta, so focused bug reports, compatibility results, documentation fixes, and
small well-tested changes are especially valuable.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting issues

Use the GitHub issue forms for reproducible bugs and feature proposals. Search
existing issues first and keep one problem or proposal per issue.

Do not report vulnerabilities in a public issue. Follow [SECURITY.md](SECURITY.md)
instead.

## Getting set up

```sh
make signing-identity   # once, so the Accessibility grant survives rebuilds
make run
```

See the README for why the signing identity matters.

## Before opening a pull request

```sh
make verify        # metadata, build, core and app regression tests
make test-runtime  # end-to-end, against the installed and running app
```

`make verify` must pass. Run `make test-runtime` as well if you touch activation,
companion lifecycle, or layout geometry — it drives the real app and checks that
groups come forward, that a companion yields the foreground, and that columns
tile the display exactly.

Pull requests should:

- explain the user-visible problem and the chosen solution;
- stay focused and avoid unrelated formatting or refactors;
- include or update regression coverage where practical;
- update documentation and `CHANGELOG.md` when behaviour changes;
- disclose any new permission, persistence, or network behaviour; and
- confirm which macOS version and hardware were used for manual testing.

## Things worth knowing

Two macOS behaviours shape a lot of this code, and both are easy to
re-introduce bugs around:

- **Cooperative activation.** Since macOS 14 a background app cannot activate
  another app. Group restoration works because the companion yields its
  activation right and the controller also raises windows through the
  Accessibility API.
- **Accessibility notifications are unreliable.** Chromium and Electron windows
  and anything with a custom title bar emit `kAXWindowMovedNotification`
  inconsistently, so nothing may depend on them alone. Window frames are read
  directly on pointer release.

Deliberately minimized groups suppress reconciliation; explicit restoration
unminimizes their members before arranging them. Frame writes share a lock, and
queued divider writes carry a cancellation session so switching groups cannot
apply stale resize work or persist obsolete results.

The runtime suite uses the Dock/LaunchServices route. Also verify native
Command-Tab manually: it sends activation without the Dock reopen callback.
Include same-app windows, minimized groups, and switching away during a restore.

## Style

Match the surrounding code. Comments explain *why* something is done — usually
which platform behaviour forced it — not what the line does.

## Licensing

By submitting a contribution, you agree that it may be distributed under the
project's [MIT License](LICENSE).
