// Extracted verbatim from Muesli-HQ/muesli
// (native/MuesliNative/Sources/MuesliNativeApp/MeetingDetector.swift, lines 27-38)
// into their own file. `MeetingDetector` — the class the rest of that donor file defines — is
// dead code in the donor: it is instantiated only by its own test file
// (Tests/MuesliTests/MeetingDetectorTests.swift), never by any production Sources/ file. The
// donor's live meeting-detection engine is `MeetingMonitor.swift`, which builds
// `MeetingCandidateResolver` and `MeetingPromptStateMachine` directly and never references
// `MeetingDetector`. So `MeetingDetector` itself, `MeetingSignals`, `MeetingActivitySnapshot`
// and `MeetingDetection` (also declared in that file) are NOT ported here — porting the dead
// class and its tests would look like proof the feature works while leaving the real engine
// unported. `CalendarEventContext` and `RunningAppInfo` are the two value types from that file
// `MeetingCandidateResolver.swift` and `MeetingMonitor.swift` actually use.
//
// One field dropped from `CalendarEventContext`: the donor declares
// `var calendarOccurrence: CalendarOccurrenceReference? = nil`. `CalendarOccurrenceReference`
// lives in the donor's separate `MuesliCore` library (`StorageModels.swift`), is part of its
// calendar-occurrence-identity/storage subsystem, and is never read by anything in
// `MeetingCandidateResolver.swift`, `MeetingPromptStateMachine.swift`, `MeetingMonitor.swift` or
// their ported companions (confirmed by grep — no `.calendarOccurrence` access anywhere in the
// ported detection code). Carrying the field would mean dragging in that unrelated subsystem
// for a value nothing here reads, so it is left off rather than invented or imported.
//
// MIT License
//
// Copyright (c) 2026 Pranav Hari
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// See NOTICE for full attribution.

import Foundation

/// Calendar event that is currently active or started within 15 minutes.
struct CalendarEventContext {
    let id: String
    let title: String
}

/// A running application on the system.
struct RunningAppInfo {
    let bundleID: String
    let isActive: Bool  // frontmost
}
