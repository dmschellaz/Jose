import AudioToolbox
import CoreAudio
import Foundation
import os

/// Silences the Mac's audio output while a session records, and puts it back afterwards. Uses the
/// output device's mute switch when it has one, otherwise turns its volume to zero. What to restore
/// is saved to UserDefaults, so a crash mid-session is undone on the next launch.
@MainActor
enum SystemAudio {
    private static let log = Logger(subsystem: "com.dmschellaz.redline", category: "audio")
    private static let savedKey = "audioRestore"   // ["device": UInt32, "kind": "mute"|"volume", "value": Float]

    static func muteOutput() {
        guard UserDefaults.standard.dictionary(forKey: savedKey) == nil else { return }   // already muted by us
        guard let device = defaultOutputDevice() else { return }
        if var mute = mutePropertyAddress(), AudioObjectHasProperty(device, &mute), isSettable(device, &mute) {
            let wasMuted: UInt32 = read(device, &mute) ?? 0
            guard wasMuted == 0 else { return }   // already silent; nothing to restore
            save(device: device, kind: "mute", value: 0)
            write(device, &mute, UInt32(1))
        } else if var volume = volumePropertyAddress(), AudioObjectHasProperty(device, &volume), isSettable(device, &volume) {
            let previous: Float32 = read(device, &volume) ?? 0
            guard previous > 0 else { return }
            save(device: device, kind: "volume", value: previous)
            write(device, &volume, Float32(0))
        } else {
            log.error("Output device \(device, privacy: .public) has no settable mute or volume; leaving audio on")
        }
    }

    /// Undoes muteOutput(). Safe to call any time, including at launch after a crash.
    static func restoreOutput() {
        guard let saved = UserDefaults.standard.dictionary(forKey: savedKey) else { return }
        UserDefaults.standard.removeObject(forKey: savedKey)
        guard let device = (saved["device"] as? NSNumber)?.uint32Value, let kind = saved["kind"] as? String else { return }
        let value = (saved["value"] as? NSNumber)?.floatValue ?? 0
        if kind == "mute", var mute = mutePropertyAddress(), AudioObjectHasProperty(device, &mute) {
            write(device, &mute, UInt32(0))
        } else if kind == "volume", var volume = volumePropertyAddress(), AudioObjectHasProperty(device, &volume) {
            write(device, &volume, Float32(value))
        }
    }

    /// True while a mute set by muteOutput() is in place (VoiceService lifts it only then).
    static var isMutedByRedline: Bool { UserDefaults.standard.dictionary(forKey: savedKey) != nil }

    // MARK: - CoreAudio helpers

    private static func save(device: AudioDeviceID, kind: String, value: Float) {
        UserDefaults.standard.set(["device": device, "kind": kind, "value": value], forKey: savedKey)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let device: AudioDeviceID? = read(AudioObjectID(kAudioObjectSystemObject), &address)
        return device == kAudioObjectUnknown ? nil : device
    }

    private static func mutePropertyAddress() -> AudioObjectPropertyAddress? {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func volumePropertyAddress() -> AudioObjectPropertyAddress? {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func isSettable(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    private static func read<T>(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> T? {
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    private static func write<T>(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress, _ value: T) {
        var value = value
        let status = AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
        if status != noErr { log.error("Couldn't change output audio (OSStatus \(status, privacy: .public))") }
    }
}
