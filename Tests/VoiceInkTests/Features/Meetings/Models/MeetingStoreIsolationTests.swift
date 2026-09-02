// The RUNTIME half of `MeetingStore`'s isolation proof.
//
// Most of the attacks on that boundary do not compile, and a test cannot assert "this does not
// compile" — those live in `scripts/negative-controls/MeetingStoreIsolationAttacks.swift` and
// are enforced by `scripts/verify-meeting-store-isolation.sh`, which builds them and fails if
// any starts compiling.
//
// The attacks in THIS file are the ones that do compile, because `Mirror` needs neither access
// nor the compiler's permission. `Mirror(reflecting:)` walks a value's stored properties
// regardless of `private`, so a design that merely hides a `ModelContext` behind an access
// modifier is one reflection hop from being defeated at runtime — and `DefaultSerialModelExecutor`
// is a *public* class with a public `modelContext`, so the recovered value would be immediately
// usable. `MeetingStore` therefore holds its engine only as a closure capture; `Mirror` reports
// no children for a closure and no API reads a closure's captures.
//
// This file is the evidence for that claim rather than the claim itself: it walks every value
// reachable from a live `MeetingStore` by reflection, to depth, and fails if any of them is a
// `ModelContext`, a `ModelExecutor`, a `ModelActor` or a managed model object.

import Foundation
import SwiftData
import Testing

@testable import VoiceInk

@Suite("MeetingStore isolation")
struct MeetingStoreIsolationTests {
    private func makeStore() throws -> MeetingStore {
        let schema = Schema([Meeting.self, MeetingSegment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return MeetingStore(modelContainer: try ModelContainer(for: schema, configurations: config))
    }

    /// One thing reflection managed to reach, and the path it was reached by.
    private struct Hazard: CustomStringConvertible {
        let path: String
        let kind: String
        let type: String
        var description: String { "\(path): \(kind) (\(type))" }
    }

    /// Breadth-first walk of everything `Mirror` can reach from `root`, reporting any value
    /// that would hand a caller write access to the store's SwiftData state.
    ///
    /// Bounded on both depth and node count so a cyclic or pathologically wide object graph
    /// cannot hang the suite; the bounds are far larger than anything this small type produces.
    private func reflectionHazards(from root: Any, maxDepth: Int = 8, maxNodes: Int = 10_000) -> [Hazard] {
        var hazards: [Hazard] = []
        var queue: [(value: Any, path: String, depth: Int)] = [(root, "store", 0)]
        var visited = 0

        while let node = queue.first {
            queue.removeFirst()
            visited += 1
            if visited > maxNodes { break }

            if node.value is ModelContext {
                hazards.append(Hazard(path: node.path, kind: "ModelContext", type: "\(type(of: node.value))"))
            }
            if node.value is any ModelExecutor {
                hazards.append(Hazard(path: node.path, kind: "ModelExecutor", type: "\(type(of: node.value))"))
            }
            if node.value is any ModelActor {
                hazards.append(Hazard(path: node.path, kind: "ModelActor", type: "\(type(of: node.value))"))
            }
            if node.value is any PersistentModel {
                hazards.append(Hazard(path: node.path, kind: "PersistentModel", type: "\(type(of: node.value))"))
            }

            guard node.depth < maxDepth else { continue }
            for (offset, child) in Mirror(reflecting: node.value).children.enumerated() {
                let label = child.label ?? "[\(offset)]"
                queue.append((child.value, "\(node.path).\(label)", node.depth + 1))
            }
        }

        return hazards
    }

    @Test("reflection cannot reach the store's ModelContext, executor, actor or model objects")
    func reflectionFindsNothingMutable() throws {
        let store = try makeStore()

        let hazards = reflectionHazards(from: store)

        #expect(hazards.isEmpty, "reflection reached: \(hazards.map(\.description).joined(separator: ", "))")
    }

    @Test("reflection still finds nothing after the store has written to its context")
    func reflectionFindsNothingAfterUse() async throws {
        let store = try makeStore()
        let meeting = try await store.startMeeting(title: "Reflected", audioDirectoryPath: "/tmp/reflect")
        try await store.appendSegment(
            startOffset: 0, endOffset: 1, speakerLabel: "You", text: "hello",
            sourceChannel: .mic, to: meeting
        )

        // Worth re-checking after real use: `startMeeting` is what causes the context to
        // register managed objects, so if anything cached a model object into a reachable
        // stored property this is when it would show up.
        let hazards = reflectionHazards(from: store)

        #expect(hazards.isEmpty, "reflection reached: \(hazards.map(\.description).joined(separator: ", "))")
    }

    @Test("the store holds no stored property that reflects to anything but closures")
    func storeHoldsOnlyClosures() throws {
        let store = try makeStore()

        // Directly pins the mechanism, not just its effect: every leaf reachable from the
        // store must be a closure, which `Mirror` reports as having no children and no
        // display style. If a future edit reintroduces a plain `let engine` stored property,
        // this fails immediately and names it, rather than waiting for the hazard walk above
        // to happen to recognise its type.
        var leaves: [(path: String, type: String, childCount: Int)] = []
        func walk(_ value: Any, path: String, depth: Int) {
            let mirror = Mirror(reflecting: value)
            if mirror.children.isEmpty {
                leaves.append((path, "\(type(of: value))", 0))
                return
            }
            guard depth < 8 else { return }
            for (offset, child) in mirror.children.enumerated() {
                walk(child.value, path: "\(path).\(child.label ?? "[\(offset)]")", depth: depth + 1)
            }
        }
        walk(store, path: "store", depth: 0)

        #expect(leaves.count == 6, "expected the six dispatch closures, got \(leaves.map(\.path))")
        for leaf in leaves {
            // A Swift closure's runtime type prints as its function type.
            #expect(
                leaf.type.contains("->"),
                "\(leaf.path) reflects to a non-closure value of type \(leaf.type)"
            )
        }
    }

    @Test("MeetingStore does not conform to ModelActor at runtime either")
    func storeIsNotAModelActor() throws {
        // The compile-time version of this attack (`func attack<A: ModelActor>(_ a: A)` and
        // `extension MeetingStore: ModelActor {}`) is in the negative-control file. This is the
        // dynamic-cast form, which does compile, and must return nil.
        let erased: Any = try makeStore()
        #expect((erased as? any ModelActor) == nil)
        #expect((erased as? any ModelExecutor) == nil)
        #expect((erased as? any Actor) == nil)
    }

    @Test("DISCLOSED HOLE: reflection does recover the PersistentIdentifier inside a handle")
    func handleReflectionIsADisclosedHole() async throws {
        // Asserted, not hidden. `MeetingHandle`'s payload is `fileprivate` to keep checked code
        // away from `ModelContext.model(for:)`; it is NOT a capability boundary and is not
        // claimed as one (see "Residual holes" on `MeetingStore`). Pinning it here means the
        // disclosure stays accurate: if a later change makes handles genuinely opaque, this
        // test fails and the documentation gets corrected rather than silently over-claiming.
        //
        // The recovered identifier grants no access to the STORE's context, which is the
        // property `MeetingStore` actually guarantees. It is only usable with a `ModelContext`
        // the attacker makes themselves, over rows they could already have fetched.
        let store = try makeStore()
        let handle = try await store.startMeeting(title: "Opaque?", audioDirectoryPath: "/tmp/opaque")

        let recovered = Mirror(reflecting: handle).children.compactMap { $0.value as? PersistentIdentifier }

        #expect(recovered.count == 1, "handle payload is no longer reachable by reflection — update the disclosure in MeetingStore.swift")
    }
}
