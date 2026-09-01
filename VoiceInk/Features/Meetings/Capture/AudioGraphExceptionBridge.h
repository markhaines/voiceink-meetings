// Ported verbatim from Muesli-HQ/muesli
// (native/MuesliNative/Sources/AudioGraphExceptionBridge/include/AudioGraphExceptionBridge.h).
//
// In the donor this is a separate SwiftPM target (its own module, imported with
// `import AudioGraphExceptionBridge`). VoiceInk.xcodeproj is a plain Xcode app target, not a
// SwiftPM package, so there is no equivalent module boundary to drop this into. It is exposed
// to the rest of the VoiceInk module instead via the bridging header
// (VoiceInk/Features/Meetings/Capture/VoiceInk-Bridging-Header.h), which #imports this file
// directly — see FORK-PATCHES.md for the one build-setting change that wires that up.
//
// Left un-renamed deliberately: the `Muesli`-prefixed symbol names below (function names, the
// error domain string, MuesliAudioInputState) are exactly the kind of cosmetic rename the
// non-negotiable porting rule for this task forbids ("do not tidy, rename, modernise, or
// restructure"). They are internal implementation names, not user-facing branding.
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

#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Result of reading AVAudioEngine's input node while inside the Objective-C
/// exception boundary. Swift cannot catch the NSExceptions AVFAudio may raise
/// while a hardware route is settling.
@interface MuesliAudioInputState : NSObject
@property(nonatomic, readonly, nullable) AVAudioFormat *outputFormat;
@property(nonatomic, readonly, nullable) NSError *error;
@end

FOUNDATION_EXPORT MuesliAudioInputState *MuesliAudioGraphReadInputState(
    AVAudioEngine *engine
);

FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphSetInputDevice(
    AVAudioEngine *engine,
    AudioObjectID deviceID
);

FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphInstallInputTap(
    AVAudioEngine *engine,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat * _Nullable format,
    AVAudioNodeTapBlock block
);
FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphPrepareEngine(AVAudioEngine *engine);
FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphStartEngine(AVAudioEngine *engine);
FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphRemoveInputTap(AVAudioEngine *engine, AVAudioNodeBus bus);
FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphStopEngine(AVAudioEngine *engine);

NS_ASSUME_NONNULL_END
