# Roadmap & Task Tracking

Work is tracked in [`backlog/`](backlog/) using [Backlog.md](https://github.com/MrLesk/Backlog.md).

- Run `backlog task list` to see prioritized work and milestones.
- Reference the task ID (for example `TASK-1`) in your branch name, PR title, or PR description when applicable.

# Branching & Pull Request Workflow

1. **Always branch off `main`** — never commit or push directly to `main`.
   - Use short, descriptive branch names with a type prefix:
     - `feat/<slug>` — new user-facing capability
     - `fix/<slug>` — bug fix
     - `refactor/<slug>` — internal restructuring without behavior change
     - `chore/<slug>` — build, tooling, dependencies, or rebrand housekeeping
     - `docs/<slug>` — documentation-only updates
2. **Keep PRs focused and small** — one logical change per pull request.
3. **Open a Pull Request against `main`** with:
   - A concise summary of **what** changed and **why**.
   - The Backlog task ID (if any) and verification output (`make test`, `make test-lifecycle`, etc.).
   - Screenshots or a short screen recording for UI or overlay changes.
4. **Merge strategy** — squash-merge PRs into `main` once tests pass and review is complete, then delete the feature branch.

# Testing Protocol

All PRs must pass the applicable test suites before merging.

## 1. Unit Tests (Required on every code change)

```bash
make test
```

Runs `swift test` across core policy, scheduling, localization, and statistics suites (`*CoreTests` and `*AppTests`).

- Every new policy, scheduler rule, or state transition must include unit tests.
- Every bug fix must include a regression test that fails without the fix.

## 2. Integration & Lifecycle Tests (Required for timer, state, or `AppDelegate` changes)

```bash
make test-lifecycle
```

Runs `scripts/test-countdown-lifecycle.py` inside a macOS `sandbox-exec` profile isolated from real user `Preferences` and `Application Support` directories, verifying end-to-end countdown lifecycle, persistence, and recovery behavior safely.

## 3. Packaging & Bundle Verification (Required for resource, plist, or build changes)

```bash
make build-app   # builds .app and runs scripts/verify-app-bundle.sh
make dmg         # builds .dmg and runs scripts/verify-dmg.sh
```

Verifies bundle layout, `Info.plist` keys, icons, resource bundles, code signature, and the `/Applications` symlink inside the DMG.

## 4. Manual Smoke Check (Required for overlay, menu bar, or multi-monitor UI changes)

Run `make run` (or `make install && make launch`) and verify:

- Break overlay covers all connected displays cleanly and dismisses without leaving residual windows.
- Menu bar controls, keyboard shortcuts, and preferences behave as expected in Light and Dark Mode.
- Sleep/lock/wake transitions leave the timer in a valid state.

# Versioning & Releases

EyeGuard follows **[Semantic Versioning](https://semver.org/)** (`MAJOR.MINOR.PATCH`):

- `PATCH` (`0.1.x`) — backwards-compatible bug fixes and polish.
- `MINOR` (`0.x.0`) — backwards-compatible new features.
- `MAJOR` (`x.0.0`) — breaking behavioral/storage changes or major architectural milestones.

## Release Checklist

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist` (and update release metadata if applicable) in a dedicated release PR (`chore/release-vX.Y.Z`).
2. Run the full verification suite:
   ```bash
   make test
   make test-lifecycle
   make dmg
   ```
   For signed and notarized public distributions, run `make release TEAM_ID=<id> DEVELOPER_ID_APPLICATION="<identity>"`.
3. Merge the release PR to `main`.
4. Tag the merge commit on `main` and push the tag:
   ```bash
   git tag -a vX.Y.Z -m "EyeGuard vX.Y.Z"
   git push origin vX.Y.Z
   ```
5. Publish a GitHub Release for `vX.Y.Z`, attach the verified `.dmg`, and include release notes following the format below.

# Release Notes Format

Keep release notes succinct, user-facing, and scannable. Group entries under **Added**, **Changed**, and **Fixed** (omit empty sections), and **link every bullet to its supporting PR**:

```markdown
# What's Changed

## Added
- Add optional Skip button to the break overlay (#12)
- Pause breaks automatically when the microphone is active in a meeting (#15)

## Fixed
- Prevent residual overlay window on secondary display after wake (#18)

**Full Changelog**: https://github.com/loic-brissot/EyeGuard/compare/v0.1.0...v0.2.0
```
