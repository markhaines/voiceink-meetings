// NEGATIVE CONTROL — this file MUST NOT COMPILE. See MeetingStoreIsolationAttacks.swift for the
// `// expect-error:` marker convention the verifier reads.
//
// A4 is alone in its own file for a reason worth stating. A retroactive conformance is recorded
// by the compiler for the whole file even when the conformance itself is an error, so putting
// this attack alongside the others made `MeetingStore` "conform to" `ModelActor` for their
// benefit: A1 (the generic `modelExecutor` escape) and A15 (`store.modelContext`) both compiled
// clean, and would have been reported as "no error found" by a less suspicious reading. Keeping
// it separate is what makes the other file's results mean anything.

import Foundation
import SwiftData

// A4. Bolt the leaking conformance back on retroactively. `ModelActor` refines `Actor`, which
// only a class or an actor can conform to, so a struct cannot be made to carry the leak — the
// choice of `struct` for `MeetingStore` is load-bearing, not stylistic.
//
// Two diagnostics land on the line below (one per protocol in the refinement chain); the marker
// names the `ModelActor` one, and the verifier's "every diagnostic lands on a marked line" rule
// accounts for the `Actor` one.
// expect-error: non-class type 'MeetingStore' cannot conform to class protocol 'ModelActor'
extension MeetingStore: ModelActor {}
