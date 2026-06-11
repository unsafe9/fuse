---
name: version-bump
description: Release a new version of Fuse end-to-end — commit any remaining changes, roll CHANGELOG.md, bump the VERSION file, create a release commit + annotated tag, push, and watch the GitHub Actions release pipeline until the dmg is published. Use whenever the user asks to bump the version, cut/ship/publish a release, tag a version, says "버전 올려", "릴리즈 해줘", "release it", "ship it", or finishes a feature and wants it out. Accepts an argument — patch (default), minor, major, or an explicit version like 1.2.3.
---

# version-bump

Releases are tag-driven: pushing a `v*` tag triggers `.github/workflows/release.yml`,
which builds the universal app, packages a dmg, and creates the GitHub Release using
that version's CHANGELOG section. This skill's job is to get the repo into a state
where that tag is truthful — everything committed, CHANGELOG and VERSION consistent —
and then to confirm the pipeline actually shipped.

The release workflow fails fast if the tag and the VERSION file disagree, so the
ordering below matters: VERSION and CHANGELOG must land in the same commit the tag
points at.

## Arguments

- *(none)* or `patch` → bump Z in X.Y.Z
- `minor` → bump Y, reset Z
- `major` → bump X, reset Y and Z
- explicit `X.Y.Z` → use as-is (must be greater than the current VERSION)

## Steps

1. **Preflight.** Confirm the current branch is `main` (releases are cut from main —
   if not, stop and ask). Run `git status` and `git log origin/main..HEAD --oneline`
   to see what is uncommitted and what is unpushed.

2. **Commit remaining changes.** If the working tree is dirty, commit everything
   before touching the version. Group into logical commits with conventional messages
   (`feat:`, `fix:`, `docs:`, `chore:`); one commit is fine when the changes belong
   together. Never leave changes behind — the tag must represent the working tree the
   user just tested. Avoid `git stash`.

3. **Compute the new version.** Read `VERSION` (single line, `X.Y.Z`) and apply the
   argument. Validate the result is strictly greater than the current version.

4. **Roll CHANGELOG.md.** The file keeps an `## [Unreleased]` section at the top.
   - Rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` (today's date).
   - If the Unreleased section is empty or missing, reconstruct the entries from
     `git log <last-tag>..HEAD --oneline` (all history when no tag exists yet),
     grouped under `### Added` / `### Changed` / `### Fixed`. Write entries for a
     user reading release notes, not commit-message shorthand.
   - Insert a fresh empty `## [Unreleased]` section above the new version section.

5. **Bump and commit.** Write the new version to `VERSION`. Commit `VERSION` +
   `CHANGELOG.md` together as `chore(release): vX.Y.Z`.

6. **Tag and push.** Create an annotated tag `vX.Y.Z` whose message is the new
   CHANGELOG section body, then `git push origin main` and `git push origin vX.Y.Z`.

7. **Watch the pipeline.** This is the success criterion — a bump that never ships is
   a failed bump.
   - `gh run list --workflow=release.yml --limit 1` to find the run for the tag, then
     `gh run watch <id> --exit-status`.
   - On success, report the release URL (`gh release view vX.Y.Z --json url`) and the
     attached dmg name.
   - On failure, fetch the failing job log (`gh run view <id> --log-failed`), report
     the cause, and leave the tag in place — fix forward with a new patch release
     instead of rewriting published tags, unless the user explicitly asks to retag.

## Example

```
/version-bump minor
```

→ commits stragglers, `0.1.3` → `0.2.0`, CHANGELOG section `## [0.2.0] - 2026-06-11`,
commit `chore(release): v0.2.0`, tag `v0.2.0`, push, then waits for the Release with
`Fuse-0.2.0.dmg` to appear.
