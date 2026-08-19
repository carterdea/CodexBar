import Foundation
import Testing
@testable import CodexBarCore

/// The seam between a real usage payload and ``AutoPrewarmDecision``.
///
/// `AutoPrewarmDecisionTests` proves every threshold at its boundary, but it feeds hand-built
/// values. These tests are what connect that to the app: if the projection below is wrong, the
/// decision is being asked the right questions about the wrong numbers.
@Suite(.serialized)
struct PrewarmSnapshotProjectionTests {
    private static func window(
        _ percent: Double,
        minutes: Int = 5 * 60,
        resetsAt: Date? = nil,
        isPlaceholder: Bool = false) -> RateWindow
    {
        RateWindow(
            usedPercent: percent,
            windowMinutes: minutes,
            resetsAt: resetsAt,
            resetDescription: nil,
            isSyntheticPlaceholder: isPlaceholder)
    }

    private static func snapshot(
        primary: RateWindow?,
        secondary: RateWindow? = nil,
        tertiary: RateWindow? = nil,
        extra: [NamedRateWindow]? = nil) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: extra,
            updatedAt: Date(timeIntervalSince1970: 1_760_000_000))
    }

    // MARK: - The session lane

    /// The case the feature exists to find: a real session lane that has never been started.
    @Test
    func `an idle session lane with no reset instant is a real session window`() {
        let snapshot = Self.snapshot(primary: Self.window(0, resetsAt: nil))
        #expect(snapshot.prewarmSessionWindow?.resetsAt == nil)
        #expect(snapshot.prewarmSessionWindow != nil)
    }

    /// The single most important line in the projection. Claude synthesises a 0% five-hour window
    /// when the account has none, and that shape — 0% used, no reset instant — is exactly what a
    /// dormant account ready to prewarm looks like. Passing it through would mean every account
    /// that had never been used qualified forever.
    @Test
    func `a synthetic placeholder is not a session window`() {
        let snapshot = Self.snapshot(primary: Self.window(0, resetsAt: nil, isPlaceholder: true))
        #expect(snapshot.prewarmSessionWindow == nil)
    }

    @Test
    func `a snapshot with no primary lane has no session window`() {
        #expect(Self.snapshot(primary: nil).prewarmSessionWindow == nil)
    }

    @Test
    func `a running session lane keeps its reset instant`() {
        let reset = Date(timeIntervalSince1970: 1_760_010_000)
        let snapshot = Self.snapshot(primary: Self.window(30, resetsAt: reset))
        #expect(snapshot.prewarmSessionWindow?.resetsAt == reset)
    }

    // MARK: - Lanes

    @Test
    func `the three positional lanes are keyed by position`() {
        let snapshot = Self.snapshot(
            primary: Self.window(10),
            secondary: Self.window(20),
            tertiary: Self.window(30))
        #expect(snapshot.prewarmLanes == ["primary": 10, "secondary": 20, "tertiary": 30])
    }

    /// Named lanes carry their own id so a model-scoped quota is compared against itself. Keying
    /// them by position instead would manufacture rises out of two unrelated quotas.
    @Test
    func `named lanes are keyed by their own id`() {
        let snapshot = Self.snapshot(
            primary: Self.window(10),
            extra: [
                NamedRateWindow(id: "fable-weekly", title: "Fable", window: Self.window(40)),
                NamedRateWindow(id: "opus-weekly", title: "Opus", window: Self.window(55)),
            ])
        #expect(snapshot.prewarmLanes == ["primary": 10, "named:fable-weekly": 40, "named:opus-weekly": 55])
    }

    /// A placeholder is a lane the provider never sent. Recording it as 0 would read as a fall now
    /// and a rise the moment the real lane appeared.
    @Test
    func `a placeholder lane is left out rather than recorded as zero`() {
        let snapshot = Self.snapshot(
            primary: Self.window(0, isPlaceholder: true),
            secondary: Self.window(60))
        #expect(snapshot.prewarmLanes == ["secondary": 60])
    }

    /// Some providers publish a named window's reset metadata before its usage. That percent is not
    /// a measurement yet.
    @Test
    func `a named lane whose usage is not yet known is left out`() {
        let snapshot = Self.snapshot(
            primary: Self.window(10),
            extra: [NamedRateWindow(
                id: "pending",
                title: "Pending",
                window: Self.window(0),
                usageKnown: false)])
        #expect(snapshot.prewarmLanes == ["primary": 10])
    }

    @Test
    func `a non-finite percent is not a measurement`() {
        let snapshot = Self.snapshot(primary: Self.window(.nan), secondary: Self.window(70))
        #expect(snapshot.prewarmLanes == ["secondary": 70])
    }

    @Test
    func `a snapshot with nothing readable produces no lanes`() {
        #expect(Self.snapshot(primary: nil).prewarmLanes.isEmpty)
    }

    /// A genuine 0% lane is a real measurement and must be kept — it is the baseline every later
    /// rise is measured from.
    @Test
    func `a genuine zero percent lane is kept`() {
        #expect(Self.snapshot(primary: Self.window(0)).prewarmLanes == ["primary": 0])
    }

    // MARK: - The sample ring

    private static let now = Date(timeIntervalSince1970: 1_760_000_000)

    private static func sample(agoMinutes: Double, percent: Double = 10) -> PrewarmSample {
        PrewarmSample(
            at: self.now.addingTimeInterval(-agoMinutes * 60),
            percentByLane: ["primary": percent])
    }

    @Test
    func `a new observation is appended`() {
        let ring = PrewarmSampleRing.appending(Self.sample(agoMinutes: 0), to: [], now: Self.now)
        #expect(ring.count == 1)
    }

    /// A refresh that read nothing is not an observation of zero usage.
    @Test
    func `a refresh with nothing to report adds nothing`() {
        let existing = [Self.sample(agoMinutes: 5)]
        #expect(PrewarmSampleRing.appending(nil, to: existing, now: Self.now).count == 1)
    }

    @Test
    func `an observation with no readable lane adds nothing`() {
        let empty = PrewarmSample(at: Self.now, percentByLane: [:])
        #expect(PrewarmSampleRing.appending(empty, to: [], now: Self.now).isEmpty)
    }

    /// Two activity windows, not one: a rise is a pair, and the earlier half of a still-valid pair
    /// can be a full window older than the later half.
    @Test
    func `a sample exactly at the horizon is still kept`() {
        let old = [PrewarmSample(
            at: Self.now.addingTimeInterval(-PrewarmSampleRing.horizon),
            percentByLane: ["primary": 5])]
        #expect(PrewarmSampleRing.appending(nil, to: old, now: Self.now).count == 1)
    }

    @Test
    func `a sample past the horizon is dropped`() {
        let old = [PrewarmSample(
            at: Self.now.addingTimeInterval(-PrewarmSampleRing.horizon - 1),
            percentByLane: ["primary": 5])]
        #expect(PrewarmSampleRing.appending(nil, to: old, now: Self.now).isEmpty)
    }

    /// The pair that a rise is actually read from has to survive pruning, or the horizon would be
    /// quietly deciding what the activity window is allowed to see.
    @Test
    func `pruning keeps a pair the decision can still read a rise from`() {
        let series = [
            Self.sample(agoMinutes: 55, percent: 10),
            Self.sample(agoMinutes: 29, percent: 40),
        ]
        let ring = PrewarmSampleRing.appending(nil, to: series, now: Self.now)
        #expect(ring.count == 2)
        #expect(AutoPrewarmDecision.lastRise(in: ring) != nil)
    }

    @Test
    func `the ring never grows past its capacity`() {
        let series = (0..<PrewarmSampleRing.capacity).map { index in
            PrewarmSample(
                at: Self.now.addingTimeInterval(-Double(index)),
                percentByLane: ["primary": 10])
        }
        let ring = PrewarmSampleRing.appending(Self.sample(agoMinutes: 0), to: series, now: Self.now)
        #expect(ring.count == PrewarmSampleRing.capacity)
    }

    /// Trimming to capacity has to drop the oldest, not the newest: the newest sample is half of
    /// every rise the decision can still detect.
    @Test
    func `trimming to capacity drops the oldest samples`() {
        let series = (0..<PrewarmSampleRing.capacity).map { index in
            PrewarmSample(
                at: Self.now.addingTimeInterval(-Double(index)),
                percentByLane: ["primary": 10])
        }
        let newest = Self.sample(agoMinutes: 0, percent: 99)
        let ring = PrewarmSampleRing.appending(newest, to: series, now: Self.now)
        #expect(ring.last == newest)
    }
}
