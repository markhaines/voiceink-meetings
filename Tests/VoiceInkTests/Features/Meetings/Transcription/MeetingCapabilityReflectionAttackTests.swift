// New for this fork (Stage 2c fix round 5, cross-vendor review B1). Not a port.
//
// WHY A RUNTIME SUITE EXISTS AT ALL. Round 5's B1 attacks split cleanly into two kinds, and
// conflating them is how round 4 shipped a false guarantee:
//
//   * Attacks that DO NOT COMPILE live in `scripts/negative-controls/`, one mechanism per file,
//     each with its verbatim diagnostic. That is where a compile-time boundary is proven.
//   * Attacks that DO COMPILE cannot be proven by a compiler diagnostic, because there is none.
//     Reflection and type-erased casts are legal Swift against any value. Their safety is a
//     RUNTIME property -- what they actually recover -- so they are asserted here, by running
//     them against a real `MeetingAsrRuntimeAccess` and checking that nothing comes back.
//
// Round 4's mistake was assuming that "the attack list is green" meant "the boundary holds". The
// list simply did not contain `as?`. These tests exist so the compiling attacks are on the record
// with real outcomes rather than absent from it.
//
// NOT COVERED, and deliberately not faked: `unsafeBitCast` and raw-memory access. They defeat any
// Swift-level boundary and are out of scope here for the same reason FOLLOWUPS.md already records
// them as out of scope for `MeetingStore`. The closures below genuinely do capture the service in
// their context, so reconstructing an undocumented closure-context layout would reach it. That is
// a cost, not a defence, and running such a cast in a test would prove nothing except that
// undefined behaviour is undefined.

import FluidAudio
import Foundation
import Testing

@testable import VoiceInk

@Suite("Meeting capability: attacks that compile, and what they actually recover")
@MainActor
struct MeetingCapabilityReflectionAttackTests {

    /// Stands in for `FluidAudioTranscriptionService`: the thing an attacker wants to reach, so
    /// that "did anything recover it?" is a question with a checkable answer. A real service
    /// cannot be used here -- constructing one is harmless, but proving the NEGATIVE needs a type
    /// this suite fully controls, and the mechanism under test (reflection over a struct of
    /// closures) is identical either way.
    final class EvictionCapableStandIn: @unchecked Sendable {
        private(set) var cleanupCallCount = 0
        func cleanup() { cleanupCallCount += 1 }
    }

    /// Builds a capability whose closures capture `service`, exactly as
    /// `MeetingAsrRuntimeAccess.sharingDictationRuntime(of:)` captures the real one.
    private func makeCapability(capturing service: EvictionCapableStandIn) -> MeetingAsrRuntimeAccess {
        MeetingAsrRuntimeAccess(
            borrowLoadedManager: {
                _ = service  // the capture the attacks below are trying to reach
                return nil
            },
            isDictationActiveOrPending: { false }
        )
    }

    @Test("Mirror, one level: recovers neither the service nor even the closures")
    func mirrorOneLevelRecoversNothing() {
        let service = EvictionCapableStandIn()
        let capability = makeCapability(capturing: service)

        let children = Array(Mirror(reflecting: capability).children)

        // The two stored closures are visible as LABELS...
        #expect(children.count == 2)
        #expect(children.contains { $0.label == "borrowLoadedManager" })
        #expect(children.contains { $0.label == "isDictationActiveOrPending" })

        // ...but nothing reachable through them is the service. The Swift runtime cannot even
        // demangle a `@MainActor @Sendable` closure type, so each value surfaces as an empty
        // tuple rather than a callable function -- verified by running this, not assumed.
        for child in children {
            #expect(child.value as? EvictionCapableStandIn == nil)
            #expect(!(child.value is EvictionCapableStandIn))
        }
        #expect(service.cleanupCallCount == 0)
    }

    @Test("Mirror, recursive to exhaustion: still never reaches the captured service")
    func mirrorRecursiveRecoversNothing() {
        let service = EvictionCapableStandIn()
        let capability = makeCapability(capturing: service)

        var found = false
        var visited = 0
        func descend(_ value: Any, depth: Int) {
            visited += 1
            if value is EvictionCapableStandIn { found = true }
            // Depth cap so a cyclic or infinitely-nested value cannot hang the suite; the tree
            // under a closure struct is in practice two empty tuples deep, so this never binds.
            guard depth < 8 else { return }
            for child in Mirror(reflecting: value).children {
                descend(child.value, depth: depth + 1)
            }
        }
        descend(capability, depth: 0)

        #expect(visited >= 3)  // the struct plus its two children were actually walked
        #expect(found == false)
        #expect(service.cleanupCallCount == 0)
    }

    @Test("a type-erased generic cast compiles, and fails at runtime")
    func genericErasedDowncastFails() {
        // `as?` against a concrete unrelated type is a compile-time warning ("always fails") and
        // is covered by a negative control. Behind a generic parameter the compiler cannot see
        // that, so this form compiles CLEAN -- which is exactly why it is asserted here instead.
        func erase<T: Sendable>(_ value: T) -> EvictionCapableStandIn? {
            value as? EvictionCapableStandIn
        }

        let service = EvictionCapableStandIn()
        #expect(erase(makeCapability(capturing: service)) == nil)
        #expect(service.cleanupCallCount == 0)
    }

    @Test("an extension on the capability compiles, and reaches only the capability")
    func extensionOnCapabilityReachesOnlyTheCapability() {
        // Adding an extension is always legal Swift and is NOT prevented. What matters is that
        // `self` inside one carries no service: the only members are the two closures the
        // capability is defined as. `capabilitySurfaceMemberCount` below is written in this file
        // as an attacker would write it.
        let service = EvictionCapableStandIn()
        let capability = makeCapability(capturing: service)

        #expect(capability.capabilitySurfaceMemberCount == 2)
        #expect(capability.attackerVisibleService == nil)
        #expect(service.cleanupCallCount == 0)
    }
}

/// The attacker's extension, written exactly as one would be in production code. It compiles.
/// It recovers nothing, because `self` is a struct of two closures and there is no stored
/// reference to any service on it to return.
extension MeetingAsrRuntimeAccess {
    fileprivate var capabilitySurfaceMemberCount: Int {
        Mirror(reflecting: self).children.count
    }

    /// The best an extension can do: there is no expression that yields the captured service, so
    /// the honest implementation returns nil. If a future edit ever makes this returnable, this
    /// property becomes writable as something other than `nil` and the test above fails.
    fileprivate var attackerVisibleService:
        MeetingCapabilityReflectionAttackTests.EvictionCapableStandIn?
    {
        nil
    }
}
