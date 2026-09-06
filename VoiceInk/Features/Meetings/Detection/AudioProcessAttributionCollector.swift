// Ported verbatim from Muesli-HQ/muesli
// (native/MuesliNative/Sources/MuesliNativeApp/AudioProcessAttributionCollector.swift).
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

import AppKit
import CoreAudio
import Foundation

struct AudioProcessActivity: Equatable {
    let pid: pid_t
    let bundleID: String
    let appName: String
    let isRunningInput: Bool
    let isRunningOutput: Bool
    let deviceIDs: [AudioObjectID]

    init(
        pid: pid_t,
        bundleID: String,
        appName: String,
        isRunningInput: Bool,
        isRunningOutput: Bool,
        deviceIDs: [AudioObjectID] = []
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
        self.deviceIDs = deviceIDs
    }
}

final class AudioProcessAttributionCollector {
    func activeInputProcesses() -> [AudioProcessActivity] {
        processObjectIDs().compactMap { processID in
            guard boolProperty(kAudioProcessPropertyIsRunningInput, objectID: processID) else {
                return nil
            }
            guard let pid = pidProperty(objectID: processID),
                  pid > 0 else { return nil }

            let bundleID = stringProperty(kAudioProcessPropertyBundleID, objectID: processID)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                ?? "pid:\(pid)"
            let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? MeetingCandidateResolver.browserApps[bundleID]
                ?? MeetingCandidateResolver.dedicatedApps[bundleID]?.name
                ?? bundleID

            return AudioProcessActivity(
                pid: pid,
                bundleID: bundleID,
                appName: appName,
                isRunningInput: true,
                isRunningOutput: boolProperty(kAudioProcessPropertyIsRunningOutput, objectID: processID),
                deviceIDs: deviceIDsForInput(processID)
            )
        }
    }

    private func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        ) == noErr else {
            return []
        }
        return ids.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private func pidProperty(objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid_t(0)
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &pid
        ) == noErr else {
            return nil
        }
        return pid
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }
        return value as String?
    }

    private func boolProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return false
        }
        return value != 0
    }

    private func deviceIDsForInput(_ objectID: AudioObjectID) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }
}
