---
name: version-bump
description: Release a new version of Fuse end-to-end — commit any remaining changes, roll the CHANGELOG, bump the VERSION file, create a release commit + annotated tag, push, and watch the GitHub Actions pipeline until the artifact is published. Fuse has TWO independent release channels — the macOS app and the Alfred workflow — and this skill handles either. Use whenever the user asks to bump the version, cut/ship/publish a release, tag a version, says "버전 올려", "릴리즈 해줘", "release it", "ship it", "워크플로우 릴리즈", or finishes a feature and wants it out. Accepts a channel (app, default — or workflow) and a bump (patch, default — minor, major, or an explicit version like 1.2.3).
---

# version-bump

Releases are tag-driven. Fuse ships **two things on two independent channels**, each with
its own version file, changelog, tag prefix, and GitHub Actions pipeline. Pushing the tag
builds the artifact and creates the GitHub Release from that version's changelog section.
This skill's job is to get the repo into a state where the tag is truthful — everything
committed, changelog and version file consistent — and then to confirm the pipeline
actually shipped.

Each pipeline fails fast if the tag and the version file disagree, so ordering matters:
the version file and changelog must land in the same commit the tag points at.

## Channels

Pick the channel from the argument (default `app`). Everything below is parameterized by
this table — substitute the channel's row into each step.

| | **app** (default) | **workflow** |
|---|---|---|
| What | the macOS menubar app | the Alfred workflow |
| Version file | `VERSION` | `alfred/VERSION` |
| Changelog | `CHANGELOG.md` | `alfred/CHANGELOG.md` |
| Tag prefix | `v` (e.g. `v1.2.3`) | `workflow-v` (e.g. `workflow-v1.2.3`) |
| Pipeline | `.github/workflows/release.yml` | `.github/workflows/release-workflow.yml` |
| Release asset | `Fuse-<version>.dmg` | `Fuse-Workflow-<version>.alfredworkflow` |
| Commit message | `chore(release): v<version>` | `chore(release): workflow-v<version>` |
| Extra step | — | regenerate `alfred/info.plist` (see step 5) |

The two versions are unrelated: an app release does **not** bump the workflow and vice
versa. App changes touch `Sources/`, `Resources/`, the app `CHANGELOG.md`, etc.; workflow
changes touch `alfred/`. A change to the AppleScript contract can require both — release
each on its own channel and note the cross-dependency in the workflow changelog.

## Arguments

`[<channel>] [<bump>]`, in any order; both optional.

- Channel: `app` (default) or `workflow`.
- Bump:
  - *(none)* or `patch` → bump Z in X.Y.Z
  - `minor` → bump Y, reset Z
  - `major` → bump X, reset Y and Z
  - explicit `X.Y.Z` → use as-is (must be greater than the current version)

Examples: `/version-bump` (app patch), `/version-bump minor` (app minor),
`/version-bump workflow` (workflow patch), `/version-bump workflow 1.1.0`.

## Steps

Let **VFILE**, **CLOG**, **PREFIX**, **PIPELINE**, **ASSET** be the chosen channel's row.

1. **Preflight.** Confirm the current branch is `main` (releases are cut from main — if
   not, stop and ask). Run `git status` and `git log origin/main..HEAD --oneline` to see
   what is uncommitted and what is unpushed.

2. **Commit remaining changes.** If the working tree is dirty, commit everything before
   touching the version — the tag must represent the tree the user just tested. Group into
   logical commits with conventional messages (`feat:`, `fix:`, `docs:`, `chore:`); one
   commit is fine when the changes belong together. Avoid `git stash`.

3. **Compute the new version.** Read **VFILE** (single line, `X.Y.Z`) and apply the bump.
   Validate the result is strictly greater than the current version.

4. **Roll CLOG.** The file keeps an `## [Unreleased]` section at the top.
   - Rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` (today's date).
   - If the Unreleased section is empty, reconstruct entries from the commits since the
     last tag of THIS channel, scoped to the channel's paths — app:
     `git log <last v* tag>..HEAD --oneline`; workflow:
     `git log <last workflow-v* tag>..HEAD --oneline -- alfred/`. Group under
     `### Added` / `### Changed` / `### Fixed`, written for someone reading release notes.
   - Insert a fresh empty `## [Unreleased]` section above the new version section.

5. **Bump, (regenerate,) and commit.** Write the new version to **VFILE**.
   - **workflow channel only:** run `python3 scripts/build_alfred_plist.py` so
     `alfred/info.plist`'s `version` field matches `alfred/VERSION` (the pipeline verifies
     this and fails otherwise). Stage `alfred/info.plist` too.
   - Commit **VFILE** + **CLOG** (+ regenerated `alfred/info.plist` for workflow) with the
     channel's commit message.

6. **Tag and push.** Create an annotated tag `PREFIX<version>` whose message is the new
   changelog section body, then `git push origin main` and `git push origin PREFIX<version>`.

7. **Watch the pipeline.** This is the success criterion — a bump that never ships is a
   failed bump.
   - `gh run list --workflow=<PIPELINE basename> --limit 1` to find the run for the tag,
     then `gh run watch <id> --exit-status`.
   - On success, report the release URL (`gh release view PREFIX<version> --json url`) and
     the attached **ASSET** name.
   - On failure, fetch the failing job log (`gh run view <id> --log-failed`), report the
     cause, and leave the tag in place — fix forward with a new patch release instead of
     rewriting published tags, unless the user explicitly asks to retag.

## Examples

```
/version-bump minor
```
→ app channel: commits stragglers, `0.1.3` → `0.2.0`, `CHANGELOG.md` section
`## [0.2.0] - 2026-06-11`, commit `chore(release): v0.2.0`, tag `v0.2.0`, push, then waits
for the Release with `Fuse-0.2.0.dmg`.

```
/version-bump workflow patch
```
→ workflow channel: `alfred/VERSION` `1.0.0` → `1.0.1`, rolls `alfred/CHANGELOG.md`,
regenerates `alfred/info.plist`, commit `chore(release): workflow-v1.0.1`, tag
`workflow-v1.0.1`, push, then waits for the Release with `Fuse-Workflow-1.0.1.alfredworkflow`.
