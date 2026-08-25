# Security Policy

## Supported versions

Window Columns is currently a public beta. Security fixes are made only on the
latest beta line.

| Version | Supported |
|---|---|
| 0.1.x beta | Yes |
| Older builds | No |

## Reporting a vulnerability

Please do not disclose a suspected vulnerability in a public issue, discussion,
or pull request.

Use GitHub's private
[vulnerability reporting form](https://github.com/maskilx/window-columns/security/advisories/new).
Include the affected version, macOS version, impact, reproduction steps, and any
suggested mitigation. If private reporting is temporarily unavailable, open a
public issue that asks the maintainer to establish private contact, without
including vulnerability details.

The maintainer will acknowledge a report as soon as practical, investigate it,
and coordinate disclosure and credit with the reporter. This volunteer project
cannot promise a fixed response-time service level.

## Security-sensitive design

Window Columns requires macOS Accessibility permission to inspect and control
windows. Window thumbnails additionally require optional Screen Recording
permission. Review [PRIVACY.md](PRIVACY.md) for the exact data and permission
use. Prebuilt beta bundles are ad-hoc signed and are not notarised; verify the
attached checksum or build a revision you trust from source.
