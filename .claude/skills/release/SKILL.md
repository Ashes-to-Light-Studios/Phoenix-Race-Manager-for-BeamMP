---
name: release
description: Release Phoenix Race Manager as a version the user names. Use when asked to release, cut, bump or publish X.Y.Z.
---

# Release PRM

**The user names the version.** Numbering is manual by design and jumps are
normal (0.23.4 went to 0.28.0). Never pick or suggest one unasked.

1. On the feature/PR branch, clean tree, with the changes listed under
   `## Unreleased` in CHANGELOG.md:

   ```bash
   python tools/release.py X.Y.Z "Short title"
   ```

   It sets the seven build stamps, titles the changelog section, rebuilds
   `package/`, runs every test and commits `Release X.Y.Z: Short title`.
   Nothing is committed if a test fails. `--dry-run` previews.

2. Push and merge the PR (`gh pr merge N --merge`). **The merge publishes**:
   `package.yml` sees a version with no tag, tags the merge commit, builds,
   releases and posts to Discord. Follow it with
   `gh run list --workflow package.yml --limit 1`.

3. If asked to deploy locally: switch to the updated `main`, then use the
   deploy skill.

A merge without a version bump publishes nothing (`gate` stops it). To
publish or re-publish by hand: `gh workflow run package.yml --ref main`.
