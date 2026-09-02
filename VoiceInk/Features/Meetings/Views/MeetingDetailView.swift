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

    private var noTranscriptView: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text("No transcript for this meeting")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
            Text("Transcription is not built yet — this meeting recorded without producing transcript text.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
