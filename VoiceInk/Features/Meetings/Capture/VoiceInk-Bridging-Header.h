// VoiceInk's Objective-C bridging header.
//
// Added for Phase 1 Stage 0 solely to expose AudioGraphExceptionBridge.h (ported from
// Muesli-HQ/muesli) to Swift. VoiceInk had no ObjC/Swift interop before this and so no
// bridging header; wiring SWIFT_OBJC_BRIDGING_HEADER to point at this file is the one
// project.pbxproj change this task makes — see FORK-PATCHES.md.
//
// FOUR PARALLEL STAGE-1 AGENTS DEPEND ON THIS FILE EXISTING AND ON THE BUILD SETTING BEING
// WIRED. Do not remove it or repoint SWIFT_OBJC_BRIDGING_HEADER without coordinating — every
// Stage-1 capture-adjacent cluster that needs to call into AudioGraphExceptionBridge.h from
// Swift relies on this exact path. If a future stage needs to bridge additional ObjC headers,
// add more #import lines here rather than creating a second bridging header (an Xcode target
// can only have one).

#import "AudioGraphExceptionBridge.h"
