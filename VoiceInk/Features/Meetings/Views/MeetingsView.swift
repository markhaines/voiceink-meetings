// Top-level Meetings screen, wired into `ContentView`'s `.meetings` case (see
// `App/Navigation/ContentView.swift` / `AppSidebar.swift`). Modeled on
// `Features/History/Views/InlineHistoryView.swift`'s list + `sidePanel` detail pattern, the
// closest existing analog: a SwiftData-backed list in the main content area with a slide-in
// detail panel rather than a separate window.
//
// The empty state below is, by a wide margin, the most likely thing anyone opening this screen
// will see for a while: transcription (Stage 2c) is not built yet, and the record control this
// screen exposes runs a genuinely honest but text-free capture — see
// `MeetingRecordingController`'s header. It is written as a real designed state, not an
// afterthought bolted onto the list view.

import SwiftData
import SwiftUI

struct MeetingsView: View {
    @Query(sort: \Meeting.startDate, order: .reverse) private var meetings: [Meeting]

    // Owned by `ContentView`, not here -- see that file's `meetingRecordingController` comment
    // for why: this view is destroyed and recreated every time the sidebar selection leaves
    // and returns to `.meetings`, and an in-progress recording must not be tied to that
    // lifecycle.
    @EnvironmentObject private var recordingController: MeetingRecordingController
    @State private var selectedMeetingID: UUID?
    @State private var isPanelPresented = false

    private var selectedMeeting: Meeting? {
        guard let selectedMeetingID else { return nil }
        return meetings.first { $0.id == selectedMeetingID }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if let message = recordingController.lastErrorMessage {
                errorBanner(message)
            }

            if meetings.isEmpty {
                emptyStateView
            } else {
                meetingListView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sidePanel(
            isPresented: .init(
                get: { isPanelPresented },
                set: { newValue in
                    isPanelPresented = newValue
                    if !newValue { selectedMeetingID = nil }
                }
            )
        ) {
            if let selectedMeeting {
                MeetingDetailView(meeting: selectedMeeting)
            }
        }
    }

    // MARK: - Top bar

    /// What "Start Meeting" actually keeps today, stated plainly and kept next to the control
    /// itself rather than only in the empty state (which stops being shown the moment a first
    /// meeting exists, while the retention behavior it describes does not change). Must stay
    /// truthful against `MeetingRecordingController`'s `retainRecording: false` and the absence
    /// of a transcription coordinator: no audio, no transcript, metadata only. See that
    /// controller's own header comment and `FOLLOWUPS.md`'s "`retainRecording` stays false"
    /// entry for why this is the current tradeoff, not an oversight.
    static let recordingDisclosureText =
        "Transcription is unavailable. Audio is captured only while the meeting runs and is " +
        "not saved; only meeting metadata is kept."

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Meetings")
                    .font(.system(size: 15, weight: .semibold))

                Spacer()

                recordButton
            }

            Text(Self.recordingDisclosureText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var recordButton: some View {
        switch recordingController.phase {
        case .idle:
            Button {
                recordingController.startMeeting(title: Self.defaultMeetingTitle())
            } label: {
                Label("Start Meeting", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.Sidebar.meetings)

        case .starting:
            Label("Starting…", systemImage: "record.circle")
                .foregroundColor(.secondary)

        case .recording:
            Button {
                recordingController.stopMeeting()
            } label: {
                Label("Stop Meeting", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.Status.error)

        case .stopping:
            Label("Stopping…", systemImage: "stop.circle")
                .foregroundColor(.secondary)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(AppTheme.Status.error)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Button {
                recordingController.lastErrorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppTheme.Status.error.opacity(0.10))
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()

            ZStack {
                Circle()
                    .fill(AppTheme.Sidebar.meetings.opacity(0.14))
                    .frame(width: 64, height: 64)
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(AppTheme.Sidebar.meetings)
            }

            Text("No meetings yet")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)

            Text(
                "Start Meeting to begin. Meetings are listed here once you stop one, with\n"
                    + "metadata only -- see the note above the list for what is and isn't kept."
            )
            .font(.system(size: 13))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 340)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var meetingListView: some View {
        Form {
            ForEach(meetings) { meeting in
                Section {
                    MeetingCardRow(meeting: meeting)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedMeetingID = meeting.id
                            isPanelPresented = true
                        }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private static func defaultMeetingTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Meeting \(formatter.string(from: Date()))"
    }
}

private struct MeetingCardRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(meeting.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    MeetingStateBadge(state: meeting.state)
                }

                Text(meeting.startDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if meeting.duration > 0 {
                Text(meeting.duration.formatTiming())
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(AppTheme.Surface.card)
                    )
                    .foregroundColor(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.vertical, 4)
    }
}

struct MeetingStateBadge: View {
    let state: MeetingState

    private var label: String {
        switch state {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .finalizing: return "Finalizing"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private var color: Color {
        switch state {
        case .recording: return AppTheme.Status.error
        case .paused: return AppTheme.Status.warningStrong
        case .finalizing: return AppTheme.Status.infoStrong
        case .completed: return AppTheme.Status.positive
        case .failed: return AppTheme.Status.error
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.16))
            )
            .foregroundColor(color)
    }
}
