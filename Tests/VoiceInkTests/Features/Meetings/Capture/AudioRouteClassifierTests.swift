// Ported verbatim from Muesli-HQ/muesli (native/MuesliNative/Tests/MuesliTests/AudioRouteClassifierTests.swift), adapted only
// to import VoiceInk instead of MuesliNativeApp — see below.
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

import CoreAudio
import Testing
@testable import VoiceInk

@Suite("AudioRouteClassifier")
struct AudioRouteClassifierTests {
    @Test("AirPods output is headphone-like")
    func airPodsOutputIsHeadphoneLike() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: nil,
                transportType: kAudioDeviceTransportTypeBluetooth,
                hasOutputStreams: true,
                hasInputStreams: true,
                outputDataSourceKinds: [kAudioStreamTerminalTypeHeadphones]
            )
        )

        #expect(route == .headphoneLike)
    }

    @Test("Bluetooth input without terminal metadata is unknown")
    func bluetoothInputWithoutTerminalMetadataIsUnknown() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: nil,
                transportType: kAudioDeviceTransportTypeBluetooth,
                hasOutputStreams: true,
                hasInputStreams: true
            )
        )

        #expect(route == .unknown)
    }

    @Test("classic Bluetooth input without terminal metadata is marked ambiguous")
    func classicBluetoothInputWithoutTerminalMetadataIsMarkedAmbiguous() {
        let classification = AudioRouteClassifier.outputRouteClassification(
            for: AudioOutputDeviceDescription(
                name: nil,
                transportType: kAudioDeviceTransportTypeBluetooth,
                hasOutputStreams: true,
                hasInputStreams: true
            )
        )

        #expect(classification.kind == .unknown)
        #expect(classification.isAmbiguousBluetooth)
    }

    @Test("Bluetooth LE input without terminal metadata is marked ambiguous")
    func bluetoothLEInputWithoutTerminalMetadataIsMarkedAmbiguous() {
        let classification = AudioRouteClassifier.outputRouteClassification(
            for: AudioOutputDeviceDescription(
                name: nil,
                transportType: kAudioDeviceTransportTypeBluetoothLE,
                hasOutputStreams: true,
                hasInputStreams: true
            )
        )

        #expect(classification.kind == .unknown)
        #expect(classification.isAmbiguousBluetooth)
    }

    @Test("generic Bluetooth output with input is unknown")
    func genericBluetoothOutputWithInputIsUnknown() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "Wireless Audio",
                transportType: kAudioDeviceTransportTypeBluetooth,
                hasOutputStreams: true,
                hasInputStreams: true
            )
        )

        #expect(route == .unknown)
    }

    @Test("Bluetooth speaker output is speaker-like when no input stream is exposed")
    func bluetoothSpeakerOutputIsSpeakerLikeWithoutInputStream() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "Generic Output",
                transportType: kAudioDeviceTransportTypeBluetooth,
                hasOutputStreams: true,
                hasInputStreams: false
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("Bluetooth high-rate generic route with input is unknown")
    func bluetoothHighRateGenericRouteWithInputIsUnknown() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "Wireless Output",
                transportType: kAudioDeviceTransportTypeBluetooth,
                hasOutputStreams: true,
                hasInputStreams: true,
                nominalSampleRate: 48_000
            )
        )

        #expect(route == .unknown)
    }

    @Test("Bluetooth headset terminal route does not depend on brand or product words")
    func bluetoothHeadsetTerminalRouteDoesNotDependOnBrandOrProductWords() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "Generic Output",
                transportType: kAudioDeviceTransportTypeBluetooth,
                hasOutputStreams: true,
                hasInputStreams: true,
                outputTerminalTypes: [kAudioStreamTerminalTypeHeadphones]
            )
        )

        #expect(route == .headphoneLike)
    }

    @Test("built-in speakers are speaker-like")
    func builtInSpeakersAreSpeakerLike() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "MacBook Pro Speakers",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                hasOutputStreams: true,
                hasInputStreams: false,
                outputTerminalTypes: [kAudioStreamTerminalTypeSpeaker]
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("wired headphones are headphone-like by terminal type")
    func wiredHeadphonesAreHeadphoneLikeByTerminalType() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "External Output",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                hasOutputStreams: true,
                hasInputStreams: false,
                outputTerminalTypes: [kAudioStreamTerminalTypeHeadphones]
            )
        )

        #expect(route == .headphoneLike)
    }

    @Test("USB headphones are headphone-like by terminal type")
    func usbHeadphonesAreHeadphoneLikeByTerminalType() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "USB Output",
                transportType: kAudioDeviceTransportTypeUSB,
                hasOutputStreams: true,
                hasInputStreams: false,
                outputTerminalTypes: [kAudioStreamTerminalTypeHeadphones]
            )
        )

        #expect(route == .headphoneLike)
    }

    @Test("USB speakers are speaker-like by terminal type")
    func usbSpeakersAreSpeakerLikeByTerminalType() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "USB Output",
                transportType: kAudioDeviceTransportTypeUSB,
                hasOutputStreams: true,
                hasInputStreams: false,
                outputTerminalTypes: [kAudioStreamTerminalTypeSpeaker]
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("mixed headphone and speaker terminals are speaker-like")
    func mixedHeadphoneAndSpeakerTerminalsAreSpeakerLike() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "Mixed Output",
                transportType: kAudioDeviceTransportTypeUSB,
                hasOutputStreams: true,
                hasInputStreams: true,
                outputTerminalTypes: [
                    kAudioStreamTerminalTypeHeadphones,
                    kAudioStreamTerminalTypeSpeaker,
                ]
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("USB headset without terminal metadata is speaker-like")
    func usbHeadsetWithoutTerminalMetadataIsSpeakerLike() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "USB Audio Device",
                transportType: kAudioDeviceTransportTypeUSB,
                hasOutputStreams: true,
                hasInputStreams: true
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("USB output without input or terminal metadata is speaker-like")
    func usbOutputWithoutInputOrTerminalMetadataIsSpeakerLike() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "USB Output",
                transportType: kAudioDeviceTransportTypeUSB,
                hasOutputStreams: true,
                hasInputStreams: false
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("Thunderbolt device without terminal metadata is speaker-like")
    func thunderboltDeviceWithoutTerminalMetadataIsSpeakerLike() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "Thunderbolt Audio Device",
                transportType: kAudioDeviceTransportTypeThunderbolt,
                hasOutputStreams: true,
                hasInputStreams: true
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("built-in output without route metadata is speaker-like")
    func builtInOutputWithoutRouteMetadataIsSpeakerLike() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "External Output",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                hasOutputStreams: true,
                hasInputStreams: false
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("selected headphone data source is headphone-like")
    func selectedHeadphoneDataSourceIsHeadphoneLike() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "Output",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                hasOutputStreams: true,
                hasInputStreams: false,
                outputDataSourceKinds: [kAudioStreamTerminalTypeHeadphones]
            )
        )

        #expect(route == .headphoneLike)
    }

    @Test("Bluetooth A2DP headphone data source is headphone-like without input stream")
    func bluetoothA2DPHeadphoneDataSourceIsHeadphoneLikeWithoutInputStream() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "Wireless Output",
                transportType: kAudioDeviceTransportTypeBluetooth,
                hasOutputStreams: true,
                hasInputStreams: false,
                outputDataSourceKinds: [kAudioStreamTerminalTypeHeadphones]
            )
        )

        #expect(route == .headphoneLike)
    }

    @Test("device names do not override transport classification")
    func deviceNamesDoNotOverrideTransportClassification() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "External Headphones",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                hasOutputStreams: true,
                hasInputStreams: false,
                outputTerminalTypes: [kAudioStreamTerminalTypeSpeaker]
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("devices without output streams are unknown")
    func devicesWithoutOutputStreamsAreUnknown() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "MacBook Pro Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                hasOutputStreams: false,
                hasInputStreams: true
            )
        )

        #expect(route == .unknown)
    }
}
