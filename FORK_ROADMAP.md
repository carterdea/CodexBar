# Fork roadmap: parity with Tokémon

What is left to bring this fork to parity with **Tokémon** (`~/Sites/claude-usage-dashboard`), the
TypeScript menu bar app these features come from. Audited 2026-08-17 against this repo at
`de63f0ce3` and Tokémon at branch `claude/codexbar-feature-integration-f78948`.

Read this before planning work. Several obvious-looking tasks are already done, and one of them is
done better here than in Tokémon.

## Where things stand

| Feature | State | Detail |
|---|---|---|
| Claude session kick | shipped | Ported verbatim, Haiku fallback list intact |
| Codex session kick | shipped | `codex exec`, argv identical, `$CODEX_HOME` routed |
| Use this next | shipped | Three-band ranking. Claude only, Codex not wired |
| Auto-kick on weekly turnover | shipped | Off by default. 60% floor, 12 hour minimum gap |
| Activity heatmap | **already here** | 365 days vs Tokémon's 105, but buried in settings and its tooltip says too little |
| Per-day detail | **already here** | Richer than Tokémon: projects, conversations, sessions |
| Lines of code written | missing | Nothing here counts edits. Blocks the digest |
| Auto-prewarm | missing | No equivalent exists |
| Monday digest | missing | No scheduled summary of any kind |
| Fun stats | partial | Spend dashboard exists. Streak, cache saved, leverage do not |

## Corrections to common assumptions

**The small-message feature is built.** Both providers. Claude is an HTTP call to `/v1/messages`,
not `claude -p`; Tokémon never used the CLI either.

**You do not need to build a calendar.** `Sources/CodexBar/SpendActivityHeatmap.swift` is a full
53-week grid with hover, keyboard navigation, month markers and VoiceOver. It renders in exactly one
place, `PreferencesSpendDashboardPane.swift:315`, and its tooltip shows a token count and a date.
The work is making it say more and putting it where you will see it.

**The kick model is `gpt-5.6-luna`**, chosen for cost. Tokémon used `gpt-5.6-sol`. The constraint
that actually matters is unchanged: never a Spark model, since Spark bills to its own
`weekly_scoped` bucket and would not open the window at all.

## The work, in the order worth doing it

### 1. Split the heatmap by provider and show cost

Tokémon's tooltip carries three lines: the date, then one line per provider with tokens and money,
omitted entirely when that provider did nothing. Ours carries a token count and a date. The colour
ramp should rank on the two providers summed, so a Codex-only day stops drawing identical to an
empty one.

- Edit `Sources/CodexBar/SpendActivityHeatmap.swift:641`
- Feed from `SpendDashboardModel.TokenActivityPoint` (`:84`)
- Money empty at zero, never `$0.00`. Zero reads as free; absent reads as unknown.

### 2. Surface the calendar in the menu

In Tokémon the grid sits in the panel under the account cards, scrolling with them. Here it is a
settings pane you have to go looking for. The menu already hosts SwiftUI in `NSMenuItem`, so the
component can move without being rebuilt: see `StatusItemController+UsageHistoryMenu.swift:15`.

Neither app draws a "today" marker. Tokémon puts today in the last column by construction.

### 3. Count lines written

We compute tokens, cost, projects and sessions but never touch edit records. Claude only: Codex
rollouts carry no edit records, which is also why per-project line counts should stay off any
merged table.

```
source   toolUseResult.structuredPatch[].lines[]  prefixed + / -
dedupe   record uuid, per file
create   type == "create" and string content, then addL = content.split("\n").length
adds     filesCreated++ per create
```

- Model: Tokémon `collector.ts:382-408`
- Target: `Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner+Claude.swift`
- New columns on `day_aggregates`, so bump the schema version

### 4. Auto-prewarm

When the account you are working in gets full, start the clock on the one you will switch to. Every
threshold is load bearing, and the dormancy check matters most: a candidate whose session window
already has a reset time does not need kicking.

```
active      a usage rise within 30 min, highest binding pct wins
            a rise is +0.5 pct between samples <= 30 min apart
trigger     active is Claude and binding pct >= 85
candidate   Claude, not the active one, headroom > 15,
            has a session window, and session.resets_at is nil
            sorted by most headroom
cooldown    not prewarmed within 5 hours
```

- Model: Tokémon `src/worker.ts:1380-1414`
- Reuse `KickCoordinator.kick(trigger: .automatic)`, which already suppresses the Keychain prompt
- `PlanUtilizationHistoryStore` keeps 2 years of hourly samples, so the rise signal is available

### 5. Monday digest

One notification a week. The range rule is the subtle part: it sums the seven days ending yesterday
as a **date range**, not the last seven stored days, because a sparse archive would otherwise fold
in a month of work.

```
when     local Monday, hour >= 9, once per week key
range    the 7 days ending yesterday, as dates
sums     cost, messages, lines added, cost per project
body     $N credit-value · N messages · +N lines · top: name
```

- Model: Tokémon `src/worker.ts:1214-1244` and `:1416-1426`
- Read from `CostUsageStore` `day_aggregates`; deliver through `AppNotifications.post`
- Depends on item 3

### 6. The stats worth keeping

Our spend dashboard already covers tokens, cost, models and projects. These are the ones Tokémon
has that we do not, and the ones with a point of view rather than another total.

```
streak        consecutive days above $0.50
              today not counting yet does NOT break it
cache saved   cacheRead * rate * 0.9, reads bill at 0.1x
leverage      lifetime cost / (accounts * $200 * months)
busiest day   both providers summed, matches the darkest cell
subagents     spend under paths containing /subagents/
```

Model: Tokémon `src/page.ts:778-843`. Pick from these; do not port wholesale. A War and Peace
comparison is charming and will be the first thing that looks like filler in a menu bar opened
forty times a day.

### 7. Wire the recommendation for Codex

The ranking is provider agnostic and already ported. Only Claude calls it, over
`claudeSwapAccountSnapshots`. Codex has managed accounts and the same question applies.

- Add to `CodexProviderImplementation.appendUsageMenuEntries`

## Open decision

**Should Spark windows stay hidden?** Tokémon drops any scoped window whose model name contains
"Spark" from everything a person reads, leaving the data intact. We show every window we receive.
Hiding is a real editorial choice about a window that cannot be acted on, worth making deliberately
rather than inheriting.

## What will bite you

- **The gatekeeper test.** `ProviderArchitectureGatekeeperTests` is 4455 lines and scans for any
  `switch provider` cluster in shipped code. Each needs a `// Provider-specific by design:` comment
  with a real reason, and its allowlist anchors are exact line numbers that shift when you insert
  code above them.
- **No CI has ever run on this fork.** Zero workflow runs, including on the merge commit. GitHub
  needs a one-time approval on the Actions tab before `ci.yml` will fire.
- **Two known-failing tests.** `StatusMenuSwitcherRefreshTests` and `MenuCardViewRecyclingTests`
  fail in isolation on upstream itself, verified against a clean clone. Not your regression.
  `CostUsageFetcherUnknownModelPricingTests` takes 106s against a 180s cap, so never build while
  testing.
- **Pricing is cached per row.** If you port a pricing table, changing a rate means bumping the
  cache version alongside it or stale rows keep serving old prices.
- **Local days, not UTC days.** A calendar cell is a pre-aggregated bucket, so the timezone has to
  be applied when the day key is written, never at display. Under UTC everything done after roughly
  5pm west of UTC lands on tomorrow's cell.
- **Still unverified.** The Claude kick has never been fired against a real account, auto-kick has
  never seen a real turnover, and 22 of the 23 localisations were written by a model, not a
  translator.
