// Meeting detail: metadata plus transcript segments in speaker + timestamp order. Modeled on
// `Features/History/Views/TranscriptionDetailView.swift`'s scroll-of-bubbles layout and
// `DesignSystem` token usage, adapted for `MeetingSegment`'s speaker/offset shape instead of
// `Transcription`'s single-text-blob shape.
//
// Segments are read directly off `meeting.segments` (a SwiftData relationship) rather than a
// fresh `@Query`, matching `Meeting.segments`'s own doc comment: cascade-deleted with the
// meeting, always loaded with it. Sorted by `(startOffset, orderIndex)` per
// `MeetingSegment.orderIndex`'s documented purpose as the tiebreaker for equal offsets.

import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting

    private var orderedSegments: [MeetingSegment] {
        meeting.segments.sorted {
            if $0.startOffset != $1.startOffset {
                return $0.startOffset < $1.startOffset
            }
            return $0.orderIndex < $1.orderIndex
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if orderedSegments.isEmpty {
                        noTranscriptView
                    } else {
                        ForEach(orderedSegments) { segment in
                            SegmentBubble(segment: segment)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(meeting.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                MeetingStateBadge(state: meeting.state)
            }

            HStack(spacing: 10) {
                Label(
                    meeting.startDate.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "calendar"
                )
                if meeting.duration > 0 {
                    Label(meeting.duration.formatTiming(), systemImage: "clock")
                }
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        .padding(16)
    }

    /// One message per `MeetingState`, not one message for all of them: the same "this meeting
    /// recorded without producing transcript text" line previously shown here regardless of
    /// state was false or premature for `.recording`/`.paused` (nothing has finished yet, so
    /// "recorded without producing" is a claim about the past that hasn't happened) and
    /// disclosed nothing about audio (transcription isn't built at all, on this branch, in any
    /// state -- but only `.completed` is actually "this is everything that will ever exist for
    /// this meeting"). Every branch states plainly what does and doesn't exist right now.
    private var noTranscriptContent: (icon: String, title: String, body: String) {
        switch meeting.state {
        case .recording:
            return (
                "record.circle",
                "Recording in progress",
                "Transcription isn't built yet, so no transcript will appear when this " +
                    "meeting stops. Audio is not being saved for later playback."
            )
        case .paused:
            return (
                "pause.circle",
                "Recording paused",
                "Transcription isn't built yet, so no transcript will appear when this " +
                    "meeting resumes and stops. Audio is not being saved for later playback."
            )
        case .finalizing:
            return (
                "hourglass",
                "Finishing up",
                "The last audio and segments are being flushed to disk. Transcription " +
                    "isn't built yet, so no transcript text will appear."
            )
        case .completed:
            return (
                "text.bubble",
                "No transcript for this meeting",
                "This meeting completed without transcript text -- transcription isn't " +
                    "built yet. Audio was not saved; only this meeting's metadata is kept."
            )
        case .failed:
            return (
                "exclamationmark.triangle",
                "This meeting did not finish cleanly",
                "Recording ended abnormally, so some or all of it may be missing -- check " +
                    "the duration above. Transcription isn't built yet regardless, so no " +
                    "transcript would exist either way."
            )
        }
    }

    private var noTranscriptView: some View {
        let content = noTranscriptContent
        return VStack(alignment: .center, spacing: 8) {
            Image(systemName: content.icon)
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text(content.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
            Text(content.body)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

private struct SegmentBubble: View {
    let segment: MeetingSegment

    private var isMic: Bool {
        segment.sourceChannel == .mic
    }

    var body: some View {
        HStack(alignment: .top) {
            if isMic { Spacer(minLength: 60) }

            VStack(alignment: isMic ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(segment.speakerLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(AppTheme.Text.muted)
                    Text(Self.offsetLabel(segment.startOffset))
                        .font(.system(size: 9))
                        .foregroundColor(AppTheme.Text.muted.opacity(0.7))
                }
                .padding(.horizontal, 12)

                Text(segment.text)
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.Text.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                            .fill(isMic ? AppTheme.Surface.subtle : AppTheme.Surface.materialCard)
                            .overlay {
                                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                                    .strokeBorder(AppTheme.Border.tint, lineWidth: 1)
                            }
                    )
            }

            if !isMic { Spacer(minLength: 60) }
        }
    }

    private static func offsetLabel(_ offset: TimeInterval) -> String {
        let minutes = Int(offset) / 60
        let seconds = Int(offset) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
