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
