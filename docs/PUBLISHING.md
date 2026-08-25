# Publishing the repository

This is the one-time checklist for publishing Window Columns as a public GitHub
repository under `maskilx/window-columns`.

## Before publishing

1. Review every file that will be public, especially window screenshots, logs,
   signing material, email addresses, tokens, and generated bundles.
2. Run `make verify` and confirm `git diff --check` reports no errors.
3. Confirm the staged changes contain the complete public beta:

   ```sh
   git status --short
   git diff --cached --stat
   git diff --cached --check
   ```

4. Create the initial commit if one does not already exist:

   ```sh
   git add --all
   git commit -m "Release 0.1.0 public beta"
   ```

## Create and push the public repository

Authenticate GitHub CLI, then create the repository from this working tree:

```sh
gh auth login --hostname github.com
gh repo create maskilx/window-columns \
  --public \
  --source=. \
  --remote=origin \
  --push \
  --description="Native macOS window groups with connected column layouts"
```

Do not pass `--add-readme`, `--gitignore`, or `--license`; the reviewed versions
in this repository are authoritative.

Apply the basic collaboration settings:

```sh
gh repo edit maskilx/window-columns \
  --enable-issues \
  --enable-wiki=false \
  --enable-projects=false \
  --enable-squash-merge \
  --delete-branch-on-merge \
  --allow-update-branch \
  --add-topic macos \
  --add-topic swift \
  --add-topic window-manager \
  --add-topic productivity
```

## Repository settings to finish in GitHub

- Enable **Private vulnerability reporting** under **Settings → Security** so
  the links in `SECURITY.md` and the issue picker work.
- Add a `main` branch ruleset after the first CI run. Require the `build` check
  for pull requests and prevent force pushes and branch deletion.
- Confirm Actions have read-only repository permissions by default.
- Confirm the About panel shows the MIT license, topics, and description.
- Review the repository while signed out to ensure only intended files and
  identity information are public.

## Publish the beta tag

Follow [RELEASING.md](RELEASING.md), then mark the GitHub release as a
prerelease. The beta is source-only; do not attach the locally signed app bundle.
