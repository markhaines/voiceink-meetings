// NEGATIVE CONTROL — this file MUST NOT COMPILE.
//
// It is deliberately kept out of every target (`scripts/` is not one of the project's
// file-system-synchronized groups, so Xcode never sees it). `scripts/verify-meeting-store-isolation.sh`
// copies it into the VoiceInk app target, builds, and fails if the build SUCCEEDS or if any
// attack stops producing its expected diagnostic. A boundary nobody re-attacks is a boundary
// that quietly rots: this is the check that fires when it does.
//
// It is compiled INTO THE APP TARGET, not the test target, on purpose. `private` and
// `fileprivate` are file-scoped, so same-module code is the realistic attacker here — the
// MeetingEngine that will eventually drive this store lives in this very module, and a boundary
// that only holds against another module would be no boundary at all.
//
// # `// expect-error:` markers, and why the expectations live here rather than in the script
//
// Each attack carries a `// expect-error: <text>` comment on the line DIRECTLY ABOVE the line
// the compiler is supposed to reject. The verifier parses these out of this file, so an
// expectation is bound to one specific LINE of one specific attack.
//
// That binding is the point, and it is a fix for a real hole. The expectations used to be a
// flat list of message strings in the script, and A3 and A14 both produce
// `'dispatch' is inaccessible due to 'private' protection level`. Either one could therefore
// have started compiling while the other still supplied the text, and the verifier would have
// stayed green while silently testing one attack instead of two. Same failure class as the one
// recorded below about A4, one notch smaller: the apparatus quietly stops testing something and
// keeps reporting success. Line-anchored markers make every control uniquely attributable, so
// that cannot happen to any attack in this file, not just those two.
//
// The verifier also asserts the converse — that every diagnostic it sees lands on a marked line
// — so a NEW kind of error cannot stand in for a missing expected one.
//
// A4 lives in its own file (`MeetingStoreRetroactiveConformanceAttack.swift`) and this one
// must not acquire a `ModelActor` conformance for `MeetingStore` by any route. That is not
// tidiness. A4 originally sat here, and even though the conformance ITSELF failed, the
// compiler still recorded it for the rest of the file — which silently made A1 and A15
// type-check clean. Two attacks reported "no error" because a THIRD attack in the same file
// had handed them the very conformance they were probing for. An attack file is evidence, so
// it has to be isolated like evidence: one conformance-mutating attack per file.
//
// Some calls below are written on one long line rather than wrapped. That is deliberate: a
// wrapped call is reported at whichever continuation line holds the offending argument, so the
// marker would have to sit in the middle of an argument list and would drift on any reformat.

import Foundation
import SwiftData

// A1. The exact attack that defeated the previous design, generalised.
// `ModelActor.modelExecutor` is a `nonisolated` public protocol requirement and
// `ModelExecutor.modelContext` is public, so ANY `ModelActor` hands out its live context
// synchronously — without the attacker naming the conforming type. The generic function itself
// is legal Swift and still compiles; what must fail is applying it to `MeetingStore`, because
// `MeetingStore` conforms to no such protocol.
func a1_genericModelExecutorEscape<A: ModelActor>(_ actor: A) {
    let context = actor.modelExecutor.modelContext
    context.autosaveEnabled = false
}

func a1_applyGenericEscapeToStore(_ store: MeetingStore) {
    // expect-error: global function 'a1_genericModelExecutorEscape' requires that 'MeetingStore' conform to 'ModelActor'
    a1_genericModelExecutorEscape(store)
}

// A2. Name the engine directly. It is `private` at file scope in MeetingStore.swift.
// expect-error: 'MeetingPersistenceEngine' is inaccessible due to 'private' protection level
func a2_nameTheEngine(_ engine: MeetingPersistenceEngine) {}

// A3. Reach the store's dispatch table, which holds the closures that capture the engine.
func a3_reachDispatch(_ store: MeetingStore) {
    // expect-error: 'dispatch' is inaccessible due to 'private' protection level
    _ = store.dispatch
}

// A5. Add an extension that unwraps a handle into a usable SwiftData key.
extension MeetingHandle {
    // expect-error: 'persistentID' is inaccessible due to 'fileprivate' protection level
    var a5_leakedIdentifier: PersistentIdentifier { persistentID }
}

// A6. Call into the store synchronously, from outside any concurrency context.
func a6_synchronousCall(_ store: MeetingStore, handle: MeetingHandle) throws {
    // expect-error: 'async' call in a function that does not support concurrency
    try store.updateState(.paused, for: handle)
}

// A7. Pass a managed, non-Sendable model object across the boundary.
func a7_passManagedObject(_ store: MeetingStore, meeting: Meeting) async throws {
    // expect-error: cannot convert value of type 'Meeting' to expected argument type 'MeetingHandle'
    try await store.appendSegment(startOffset: 0, endOffset: 1, speakerLabel: "You", text: "x", sourceChannel: .mic, to: meeting)
}

// A8. The same, laundered through a generic so no concrete model type is named at the call site.
func a8_passManagedObjectGenerically<M: PersistentModel>(_ store: MeetingStore, model: M) async throws {
    // expect-error: cannot convert value of type 'M' to expected argument type 'MeetingHandle'
    try await store.updateDuration(1, for: model)
}

// A9. Forge a handle from an identifier obtained some other way (e.g. a plain fetch).
func a9_forgeHandle(_ id: PersistentIdentifier) -> MeetingHandle {
    // expect-error: 'MeetingHandle' initializer is inaccessible due to 'fileprivate' protection level
    MeetingHandle(id)
}

// A10. Reconstruct a handle through Codable. `PersistentIdentifier` is `Codable`; the handle
// deliberately is not, so there is no decode route back to one.
func a10_decodeHandle(_ data: Data) throws -> MeetingHandle {
    // expect-error: instance method 'decode(_:from:)' requires that 'MeetingHandle' conform to 'Decodable'
    try JSONDecoder().decode(MeetingHandle.self, from: data)
}

// A11. Hand the store a context somebody else already owns, instead of a container it will make
// its own context from.
func a11_initFromForeignContext(_ context: ModelContext) -> MeetingStore {
    // expect-error: incorrect argument label in call (have 'modelContext:', expected 'modelContainer:')
    MeetingStore(modelContext: context)
}

// A12. Subclass to override or expose internals. `MeetingStore` is a struct.
// expect-error: inheritance from non-protocol, non-class type 'MeetingStore'
final class A12_SubclassTheStore: MeetingStore {}

// A13. Reach the container the store was built from. `@ModelActor` would have exposed this as a
// `nonisolated` property; this design stores no such thing.
func a13_reachContainer(_ store: MeetingStore) -> ModelContainer {
    // expect-error: value of type 'MeetingStore' has no member 'modelContainer'
    store.modelContainer
}

// A14. Key-path route to the private dispatch table, which is a different access mechanism from
// A3's member reference. Shares A3's diagnostic TEXT, which is exactly why expectations are
// anchored to lines rather than matched by string; see this file's header.
func a14_keyPathToDispatch() -> PartialKeyPath<MeetingStore> {
    // expect-error: 'dispatch' is inaccessible due to 'private' protection level
    \MeetingStore.dispatch
}

// A15. Read the engine's context through the store by any other member name it might expose.
func a15_reachModelContext(_ store: MeetingStore) -> ModelContext {
    // expect-error: value of type 'MeetingStore' has no member 'modelContext'
    store.modelContext
}
