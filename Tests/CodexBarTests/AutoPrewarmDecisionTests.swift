import Foundation
import Testing
@testable import CodexBarCore

/// This decision sends a message on an account the user is not even looking at, so nearly every
/// case here is about it staying silent. A missed prewarm costs a switch that lands on a cold
/// window; a wrong one opens a 5-hour window nobody asked for on an account nobody was using.
@Suite(.serialized)
struct AutoPrewarmDecisionTests {
    private static let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - Fixtures

    private static func window(_ percent: Double, resetsAt: Date? = nil) -> RateWindow {
        RateWindow(
            usedPercent: percent,
            windowMinutes: 7 * 24 * 60,
            resetsAt: resetsAt,
            resetDescription: nil)
    }

    private static func session(_ percent: Double, resetsAt: Date?) -> RateWindow {
        RateWindow(
            usedPercent: percent,
            windowMinutes: 5 * 60,
            resetsAt: resetsAt,
            resetDescription: nil)
    }

    /// Two samples `minutesApart` apart whose session lane climbed by `rise` points, the later one
    /// landing `endingAgo` before ``now``.
    private static func risingSamples(
        rise: Double = 1,
        minutesApart: Double = 10,
        endingAgo: TimeInterval = 0) -> [PrewarmSample]
    {
        let later = self.now.addingTimeInterval(-endingAgo)
        return [
            PrewarmSample(at: later.addingTimeInterval(-minutesApart * 60), percentByLane: ["session": 10]),
            PrewarmSample(at: later, percentByLane: ["session": 10 + rise]),
        ]
    }

    private static func account(
        _ key: String,
        percent: Double,
        sessionResetsAt: Date? = nil,
        hasSessionWindow: Bool = true,
        samples: [PrewarmSample] = [],
        lastPrewarmedAt: Date? = nil,
        canStartSessionWindow: Bool = true) -> PrewarmAccount
    {
        PrewarmAccount(
            key: key,
            windows: [self.window(percent)],
            sessionWindow: hasSessionWindow ? self.session(0, resetsAt: sessionResetsAt) : nil,
            samples: samples,
            lastPrewarmedAt: lastPrewarmedAt,
            canStartSessionWindow: canStartSessionWindow)
    }

    /// The ordinary case the whole feature exists for: a busy account and one dormant spare.
    private static func standardPair(
        activePercent: Double = 90,
        candidatePercent: Double = 20,
        candidateSessionResetsAt: Date? = nil,
        candidateHasSessionWindow: Bool = true,
        candidateLastPrewarmedAt: Date? = nil,
        candidateCanStartSessionWindow: Bool = true,
        samples: [PrewarmSample] = AutoPrewarmDecisionTests.risingSamples()) -> [PrewarmAccount]
    {
        [
            self.account("busy", percent: activePercent, samples: samples),
            self.account(
                "spare",
                percent: candidatePercent,
                sessionResetsAt: candidateSessionResetsAt,
                hasSessionWindow: candidateHasSessionWindow,
                lastPrewarmedAt: candidateLastPrewarmedAt,
                canStartSessionWindow: candidateCanStartSessionWindow),
        ]
    }

    private static func candidateKey(
        _ accounts: [PrewarmAccount],
        isEnabled: Bool = true,
        lastPrewarmOfAnyAccountAt: Date? = nil) -> String?
    {
        AutoPrewarmDecision.candidate(
            isEnabled: isEnabled,
            accounts: accounts,
            lastPrewarmOfAnyAccountAt: lastPrewarmOfAnyAccountAt,
            now: self.now)?.key
    }

    // MARK: - The happy path

    @Test
    func `a full active account prewarms the dormant spare`() {
        #expect(Self.candidateKey(Self.standardPair()) == "spare")
    }

    @Test
    func `the setting being off beats every other condition`() {
        #expect(Self.candidateKey(Self.standardPair(), isEnabled: false) == nil)
    }

    @Test
    func `the account judged is the one returned`() {
        let accounts = [
            Self.account("busy", percent: 90, samples: Self.risingSamples()),
            Self.account("roomier", percent: 10),
            Self.account("tighter", percent: 40),
        ]
        #expect(Self.candidateKey(accounts) == "roomier")
    }

    // MARK: - The trigger threshold

    /// 85 exactly is a trigger: the threshold is "this full or fuller".
    @Test
    func `the trigger fires exactly at its threshold`() {
        #expect(Self.candidateKey(Self.standardPair(activePercent: 85)) == "spare")
    }

    @Test
    func `just under the trigger sends nothing`() {
        #expect(Self.candidateKey(Self.standardPair(activePercent: 84.9)) == nil)
    }

    // MARK: - The headroom threshold

    /// Headroom is strictly greater than 15, so a candidate at exactly 85% used does not qualify —
    /// it is as full as the account being abandoned.
    @Test
    func `a candidate with exactly the minimum headroom is refused`() {
        #expect(Self.candidateKey(Self.standardPair(candidatePercent: 85)) == nil)
    }

    @Test
    func `a candidate just over the minimum headroom qualifies`() {
        #expect(Self.candidateKey(Self.standardPair(candidatePercent: 84.9)) == "spare")
    }

    /// The binding percentage is the *highest* window, not the weekly one, so a candidate with a
    /// roomy week and an exhausted model lane is not a place to switch to.
    @Test
    func `headroom reads the binding window rather than the roomiest one`() {
        let spare = PrewarmAccount(
            key: "spare",
            windows: [Self.window(10), Self.window(95)],
            sessionWindow: Self.session(0, resetsAt: nil),
            samples: [],
            lastPrewarmedAt: nil,
            canStartSessionWindow: true)
        #expect(Self.candidateKey([Self.account("busy", percent: 90, samples: Self.risingSamples()), spare]) == nil)
    }

    // MARK: - Dormancy

    /// The check that matters most. An account whose session window already has a reset instant has
    /// a clock running, so a message buys nothing at all.
    @Test
    func `an account whose session clock is already running is not prewarmed`() {
        let running = Self.now.addingTimeInterval(3 * 3600)
        #expect(Self.candidateKey(Self.standardPair(candidateSessionResetsAt: running)) == nil)
    }

    /// A provider that reported no session lane is not the same as one reporting an unstarted
    /// window. Treating the two alike would prewarm every account that has never been used.
    @Test
    func `an account with no session window at all is not prewarmed`() {
        #expect(Self.candidateKey(Self.standardPair(candidateHasSessionWindow: false)) == nil)
    }

    @Test
    func `the account being used is never its own candidate`() {
        let onlyBusy = [Self.account("busy", percent: 90, samples: Self.risingSamples())]
        #expect(Self.candidateKey(onlyBusy) == nil)
    }

    // MARK: - Whether a message can be sent at all

    /// A Claude token account may hold web cookies or an admin API key instead of an OAuth token,
    /// and neither can send an inference request.
    @Test
    func `an account nothing can be sent on is never the candidate`() {
        #expect(Self.candidateKey(Self.standardPair(candidateCanStartSessionWindow: false)) == nil)
    }

    /// The reason this is a rule and not a nicety. Ranking an unsendable account puts it in front
    /// of the one that works, and since the caller records the cooldown before it sends, that spare
    /// would stay blocked for five hours at a time and never be prewarmed at all.
    @Test
    func `an unsendable account does not outrank the one that can be prewarmed`() {
        let accounts = [
            Self.account("busy", percent: 90, samples: Self.risingSamples()),
            Self.account("roomy-but-unsendable", percent: 5, canStartSessionWindow: false),
            Self.account("sendable", percent: 40),
        ]
        #expect(Self.candidateKey(accounts) == "sendable")
    }

    /// Being unable to send *on* an account says nothing about whether someone is working *in* it.
    /// A user typing into a cookie-backed account still wants their OAuth spare warmed up.
    @Test
    func `an account nothing can be sent on can still be the one in use`() {
        let accounts = [
            Self.account("busy", percent: 90, samples: Self.risingSamples(), canStartSessionWindow: false),
            Self.account("spare", percent: 20),
        ]
        #expect(Self.candidateKey(accounts) == "spare")
    }

    // MARK: - The cooldown

    @Test
    func `a candidate prewarmed inside the cooldown is skipped`() {
        let recent = Self.now.addingTimeInterval(-(AutoPrewarmDecision.cooldown - 1))
        #expect(Self.candidateKey(Self.standardPair(candidateLastPrewarmedAt: recent)) == nil)
    }

    /// Exactly one window later the previous prewarm has expired, so a new one can start.
    @Test
    func `a candidate prewarmed exactly one cooldown ago is eligible again`() {
        let expired = Self.now.addingTimeInterval(-AutoPrewarmDecision.cooldown)
        #expect(Self.candidateKey(Self.standardPair(candidateLastPrewarmedAt: expired)) == "spare")
    }

    /// The decision runs on every usage refresh, and a successful prewarm triggers a refresh of its
    /// own. Without this rule one busy account would walk down the list and message every dormant
    /// account it had, in one cycle.
    @Test
    func `a second account is not prewarmed while another prewarm is still recent`() {
        let accounts = [
            Self.account("busy", percent: 90, samples: Self.risingSamples()),
            Self.account("first", percent: 10),
            Self.account("second", percent: 20),
        ]
        let justNow = Self.now.addingTimeInterval(-60)
        #expect(Self.candidateKey(accounts, lastPrewarmOfAnyAccountAt: justNow) == nil)
    }

    @Test
    func `another account becomes eligible exactly one cooldown after the last prewarm`() {
        let expired = Self.now.addingTimeInterval(-AutoPrewarmDecision.cooldown)
        #expect(Self.candidateKey(Self.standardPair(), lastPrewarmOfAnyAccountAt: expired) == "spare")
    }

    @Test
    func `one prewarm short of a cooldown ago still blocks every account`() {
        let recent = Self.now.addingTimeInterval(-(AutoPrewarmDecision.cooldown - 1))
        #expect(Self.candidateKey(Self.standardPair(), lastPrewarmOfAnyAccountAt: recent) == nil)
    }

    // MARK: - Detecting the account in use

    @Test
    func `a rise of exactly the threshold is not a rise`() {
        #expect(Self.candidateKey(Self.standardPair(samples: Self.risingSamples(rise: 0.5))) == nil)
    }

    @Test
    func `a rise just over the threshold counts`() {
        #expect(Self.candidateKey(Self.standardPair(samples: Self.risingSamples(rise: 0.51))) == "spare")
    }

    @Test
    func `samples straddling more than the activity window cannot show a rise`() {
        #expect(Self.candidateKey(Self.standardPair(samples: Self.risingSamples(minutesApart: 30.1))) == nil)
    }

    @Test
    func `samples exactly the activity window apart still count`() {
        #expect(Self.candidateKey(Self.standardPair(samples: Self.risingSamples(minutesApart: 30))) == "spare")
    }

    @Test
    func `a rise older than the activity window no longer means the account is in use`() {
        let stale = Self.risingSamples(endingAgo: AutoPrewarmDecision.activityWindow)
        #expect(Self.candidateKey(Self.standardPair(samples: stale)) == nil)
    }

    @Test
    func `a rise just inside the activity window still means the account is in use`() {
        let fresh = Self.risingSamples(endingAgo: AutoPrewarmDecision.activityWindow - 1)
        #expect(Self.candidateKey(Self.standardPair(samples: fresh)) == "spare")
    }

    /// The case adjacent-pair comparison gets wrong. No single step clears the threshold, but the
    /// climb across half an hour is well over it, and this is what a slow burn looks like whenever
    /// the app refreshes often enough to split the work into small steps.
    @Test
    func `a rise accumulated across three samples counts`() {
        let creeping = [
            PrewarmSample(at: Self.now.addingTimeInterval(-20 * 60), percentByLane: ["session": 20.0]),
            PrewarmSample(at: Self.now.addingTimeInterval(-10 * 60), percentByLane: ["session": 20.3]),
            PrewarmSample(at: Self.now, percentByLane: ["session": 20.6]),
        ]
        #expect(Self.candidateKey(Self.standardPair(samples: creeping)) == "spare")
    }

    /// The accumulation is still bounded by the activity window: reaching further back than that
    /// would let a climb from an hour ago read as someone typing now.
    @Test
    func `an accumulated rise reaching past the activity window does not count`() {
        let spread = [
            PrewarmSample(at: Self.now.addingTimeInterval(-31 * 60), percentByLane: ["session": 20.0]),
            PrewarmSample(at: Self.now.addingTimeInterval(-16 * 60), percentByLane: ["session": 20.3]),
            PrewarmSample(at: Self.now, percentByLane: ["session": 20.6]),
        ]
        #expect(Self.candidateKey(Self.standardPair(samples: spread)) == nil)
    }

    @Test
    func `a single sample cannot establish a rise`() {
        let one = [PrewarmSample(at: Self.now, percentByLane: ["session": 90])]
        #expect(Self.candidateKey(Self.standardPair(samples: one)) == nil)
    }

    @Test
    func `an account with no samples is never the active one`() {
        #expect(Self.candidateKey(Self.standardPair(samples: [])) == nil)
    }

    /// The rise has to be looked for in every lane. An hour of work can move the 5-hour lane twenty
    /// points while the weekly lane it sits behind — the binding one — barely moves, so a decision
    /// reading only the binding number would call the busiest account idle.
    @Test
    func `a rise in a lane other than the binding one still counts`() {
        let samples = [
            PrewarmSample(
                at: Self.now.addingTimeInterval(-600),
                percentByLane: ["session": 10, "weekly": 90]),
            PrewarmSample(at: Self.now, percentByLane: ["session": 30, "weekly": 90]),
        ]
        #expect(Self.candidateKey(Self.standardPair(samples: samples)) == "spare")
    }

    /// A lane appearing for the first time is not a climb from zero, it is a lane nobody measured
    /// before. Reading it as a rise would mark an account active the moment a model quota shows up.
    @Test
    func `a lane appearing for the first time is not a rise`() {
        let samples = [
            PrewarmSample(at: Self.now.addingTimeInterval(-600), percentByLane: ["session": 10]),
            PrewarmSample(at: Self.now, percentByLane: ["session": 10, "fable-weekly": 40]),
        ]
        #expect(Self.candidateKey(Self.standardPair(samples: samples)) == nil)
    }

    @Test
    func `a lane that fell back after a reset is not a rise`() {
        let samples = [
            PrewarmSample(at: Self.now.addingTimeInterval(-600), percentByLane: ["session": 80]),
            PrewarmSample(at: Self.now, percentByLane: ["session": 2]),
        ]
        #expect(Self.candidateKey(Self.standardPair(samples: samples)) == nil)
    }

    @Test
    func `the most recent rise is the one reported`() {
        let older = Self.now.addingTimeInterval(-3600)
        let samples = [
            PrewarmSample(at: older.addingTimeInterval(-600), percentByLane: ["session": 10]),
            PrewarmSample(at: older, percentByLane: ["session": 20]),
            PrewarmSample(at: Self.now.addingTimeInterval(-600), percentByLane: ["session": 20]),
            PrewarmSample(at: Self.now, percentByLane: ["session": 40]),
        ]
        #expect(AutoPrewarmDecision.lastRise(in: samples) == Self.now)
    }

    /// Samples arrive from a store that makes no ordering promise, so the reader sorts them.
    /// Without that, an out-of-order pair reads as a fall and the account looks idle.
    @Test
    func `samples are ordered before they are compared`() {
        let shuffled = Array(Self.risingSamples().reversed())
        #expect(AutoPrewarmDecision.lastRise(in: shuffled) == Self.now)
    }

    // MARK: - Choosing between several accounts

    /// The fullest of the recently active accounts is the one about to force a switch.
    @Test
    func `the fullest recently active account is treated as the one in use`() {
        let accounts = [
            Self.account("nearly-full", percent: 90, samples: Self.risingSamples()),
            Self.account("busy-but-roomy", percent: 30, samples: Self.risingSamples()),
            Self.account("spare", percent: 10),
        ]
        #expect(AutoPrewarmDecision.activeAccount(among: accounts, now: Self.now)?.key == "nearly-full")
        #expect(Self.candidateKey(accounts) == "spare")
    }

    /// A second active account is still a candidate if it is dormant and roomy: "active" only names
    /// which account triggers the decision, not which ones are off limits.
    @Test
    func `the roomiest eligible candidate wins`() {
        let accounts = [
            Self.account("busy", percent: 90, samples: Self.risingSamples()),
            Self.account("some-room", percent: 60),
            Self.account("most-room", percent: 5),
            Self.account("no-room", percent: 99),
        ]
        #expect(Self.candidateKey(accounts) == "most-room")
    }

    /// Ties are broken by name so the choice cannot shuffle between refreshes and send a message on
    /// a different account each cycle.
    @Test
    func `equal headroom is broken by name`() {
        let accounts = [
            Self.account("busy", percent: 90, samples: Self.risingSamples()),
            Self.account("zulu", percent: 20),
            Self.account("alpha", percent: 20),
        ]
        #expect(Self.candidateKey(accounts) == "alpha")
    }

    @Test
    func `nothing is prewarmed when no account is in use`() {
        #expect(Self.candidateKey([Self.account("busy", percent: 90), Self.account("spare", percent: 10)]) == nil)
    }

    @Test
    func `an empty account list decides nothing`() {
        #expect(Self.candidateKey([]) == nil)
    }

    /// An account reporting no usable window has no binding percentage, so neither its fullness nor
    /// its headroom is known. Guessing either way would be inventing a number.
    @Test
    func `an account with no readable windows is neither active nor a candidate`() {
        let unreadable = PrewarmAccount(
            key: "unreadable",
            windows: [],
            sessionWindow: Self.session(0, resetsAt: nil),
            samples: Self.risingSamples(),
            lastPrewarmedAt: nil,
            canStartSessionWindow: true)
        #expect(AutoPrewarmDecision.activeAccount(among: [unreadable], now: Self.now) == nil)
        let busy = Self.account("busy", percent: 90, samples: Self.risingSamples())
        #expect(Self.candidateKey([busy, unreadable]) == nil)
    }
}
