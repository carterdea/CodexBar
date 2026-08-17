# Fork changelog

Changes made in `carterdea/CodexBar` that are not in `steipete/CodexBar`.

Kept separate from `CHANGELOG.md` on purpose: upstream's changelog is ~235 KB and rewritten on
every release, so editing it guarantees a conflict on every sync. Nothing in this file should ever
appear in that one.

## Unreleased

### Fork setup

- Releasing is disabled rather than misconfigured. `Scripts/package_app.sh` now ships an empty
  `SUFeedURL` and `SUPublicEDKey` for every configuration, and `.mac-release.env` has had the
  upstream author's Sparkle key, Developer ID identity, and 1Password item references removed.
  A build from this fork cannot offer to update itself into upstream's app, and `make release`
  cannot sign or notarize as someone else. Restoring releases means generating a fork-owned
  Sparkle keypair and Developer ID identity first.
- `make start-release` and the `AGENTS.md` relaunch instructions no longer point at the upstream
  author's home directory; they resolve the repo root instead.
- Bundle ID stays `com.steipete.codexbar`. Renaming it touches ~25 hard-coded sites, orphans
  existing Keychain cache entries and config, and loses iCloud Sync until a CloudKit container is
  provisioned. It is a separate change, not a prerequisite for anything here.

### Added

- **Kick a Claude account** — send one minimal message so the 5-hour session window starts now
  instead of whenever the next real request lands. `Sources/CodexBarCore/Kick/`.
- **Kick a Codex account** — same idea, but it has to be a throwaway `codex exec` rather than an
  HTTP call, because the ChatGPT backend starts the window off actual Codex usage. Routed to the
  active account's `CODEX_HOME`, since `codex exec` has no flag to select a login.

### Added

- **"Use X next"** — one line in Claude's menu naming the account with the most headroom, when
  there is a real choice to make. Backed by `AccountRanking`.

### Known upstream failures

Two tests around the merged menu fail **in isolation on upstream itself**, verified against an
untouched clone of `steipete/CodexBar` at `45ca0b4` with no fork changes present:

- `StatusMenuSwitcherRefreshTests` / "merged provider switch updates live tab rows in place" —
  the same two `ObjectIdentifier` expectations fail there.
- `MenuCardViewRecyclingTests` / "merged data tick keeps row count and card views stable" — a
  data-only repopulate grows the row count by 2. Upstream fails 16 → 18; this fork fails 17 → 19,
  the same +2 defect offset by the one row the Codex kick adds.

It matters here because `Scripts/ci_swift_test_by_suite.py` batches 12 suites per group, so *adding
a test file anywhere* can reshuffle groups and flip this test between passing and failing. It passed
in a full run before `MenuDescriptorClaudeKickTests` was added and failed in the run after — the new
tests were the trigger, not the cause.

Until it is fixed upstream, a red `make test` should be checked against this one test before it is
treated as a regression.
