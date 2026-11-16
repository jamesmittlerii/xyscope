import AVFoundation
import Foundation
import os

#if os(macOS)
import CoreAudio
#endif

struct InputDevice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var manufacturer: String
}

struct CaptureStatus: Sendable {
    var deviceName: String
    var sampleRate: Double
    var bufferFrames: Int
}

enum CaptureError: LocalizedError {
    case noStereoInput
    case unsupportedFormat(String)
    case cannotStart(OSStatus)
    case cannotConfigure(String)

    var errorDescription: String? {
        switch self {
        case .noStereoInput:
            return "No stereo input is connected."
        case .unsupportedFormat(let detail):
            return "The input format is not stereo PCM (\(detail))."
        case .cannotStart(let status):
            return "Could not start the input (\(status))."
        case .cannotConfigure(let detail):
            return "Could not configure the input (\(detail))."
        }
    }
}

/// Captures stereo line input into the ring. macOS uses the Core Audio HAL;
/// iPadOS uses AVAudioEngine so class-compliant USB interfaces (UCA202) work
/// through the Camera Connection Kit / USB-C adapter.
final class AudioCapture: @unchecked Sendable {
    private let ring: SampleRing
    private let log = Logger(subsystem: "com.rheosoft.oscope", category: "audio")

    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 8_192

    #if os(macOS)
    private var deviceID: AudioDeviceID = 0
    private var procID: AudioDeviceIOProcID?
    private var sampleKind: SampleKind = .float32

    private enum SampleKind {
        case float32
        case int16
    }
    #else
    private let engine = AVAudioEngine()
    private var runningDeviceID: String?
    #endif

    init(ring: SampleRing) {
        self.ring = ring
        scratch = .allocate(capacity: scratchFrames * 2)
        scratch.initialize(repeating: 0, count: scratchFrames * 2)
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    static func preferredDevice(in devices: [InputDevice]) -> String? {
        if let named = devices.first(where: { $0.name.localizedCaseInsensitiveContains("UCA202") }) {
            return named.id
        }
        let codecs = devices.filter { $0.name.localizedCaseInsensitiveContains("USB Audio CODEC") }
        if let burr = codecs.first(where: {
            $0.manufacturer.localizedCaseInsensitiveContains("Burr-Brown")
                || $0.manufacturer.localizedCaseInsensitiveContains("Texas Instruments")
        }) {
            return burr.id
        }
        if let codec = codecs.first {
            return codec.id
        }
        if let usb = devices.first(where: {
            $0.name.localizedCaseInsensitiveContains("USB")
                || $0.manufacturer.localizedCaseInsensitiveContains("USB")
        }) {
            return usb.id
        }
        #if os(macOS)
        if let fallback = defaultInputID(), devices.contains(where: { $0.id == String(fallback) }) {
            return String(fallback)
        }
        #else
        if let current = AVAudioSession.sharedInstance().preferredInput?.uid
            ?? AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid,
           devices.contains(where: { $0.id == current }) {
            return current
        }
        #endif
        return devices.first?.id
    }

    #if os(macOS)
    static func inputDevices() -> [InputDevice] {
        deviceIDs().compactMap { id in
            let channels = inputChannelCount(id)
            guard channels >= 2 else { return nil }
            return InputDevice(
                id: String(id),
                name: stringProperty(id, kAudioObjectPropertyName),
                manufacturer: stringProperty(id, kAudioObjectPropertyManufacturer)
            )
        }
    }

    func start(device id: String) throws -> CaptureStatus {
        guard let numericID = AudioDeviceID(id) else {
            throw CaptureError.cannotConfigure("Unknown device \(id)")
        }
        stop()
        let format = try streamFormat(numericID)
        sampleKind = format.kind
        try lockSampleRate(numericID)
        let frames = setBufferFrames(numericID, preferred: 1_024)
        let rate = nominalSampleRate(numericID)

        let unmanaged = Unmanaged.passUnretained(self).toOpaque()
        var proc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&proc, numericID, nil) { _, inputData, _, _, _ in
            let capture = Unmanaged<AudioCapture>.fromOpaque(unmanaged).takeUnretainedValue()
            capture.consume(inputData)
        }
        guard created == noErr, let proc else {
            throw CaptureError.cannotStart(created)
        }
        let started = AudioDeviceStart(numericID, proc)
        if started != noErr {
            AudioDeviceDestroyIOProcID(numericID, proc)
            throw CaptureError.cannotStart(started)
        }
        deviceID = numericID
        procID = proc
        let name = Self.stringProperty(numericID, kAudioObjectPropertyName)
        log.info("Opened \(name, privacy: .public) at \(rate, format: .fixed(precision: 0)) Hz, \(frames) frames, \(String(describing: format.kind), privacy: .public)")
        return CaptureStatus(deviceName: name, sampleRate: rate, bufferFrames: frames)
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.procID = nil
    }
    #else
    static func inputDevices() -> [InputDevice] {
        let session = AVAudioSession.sharedInstance()
        prepareSession(session)
        let ports = session.availableInputs ?? []
        return ports.map { port in
            InputDevice(
                id: port.uid,
                name: port.portName,
                manufacturer: port.portType.rawValue
            )
        }
    }

    func start(device id: String) throws -> CaptureStatus {
        stop()
        let session = AVAudioSession.sharedInstance()
        try Self.configureSession(session)
        if let preferred = session.availableInputs?.first(where: { $0.uid == id }) {
            try session.setPreferredInput(preferred)
        }
        try session.setActive(true, options: [])
        engine.reset()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount >= 2 else {
            throw CaptureError.noStereoInput
        }
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw CaptureError.unsupportedFormat("\(format.commonFormat)")
        }

        let bufferFrames = max(Int((session.ioBufferDuration * format.sampleRate).rounded()), 256)
        let unmanaged = Unmanaged.passUnretained(self).toOpaque()
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(bufferFrames), format: format) { buffer, _ in
            let capture = Unmanaged<AudioCapture>.fromOpaque(unmanaged).takeUnretainedValue()
            capture.consume(buffer: buffer, channels: Int(format.channelCount))
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.cannotConfigure(error.localizedDescription)
        }
        runningDeviceID = id
        let name = session.currentRoute.inputs.first?.portName
            ?? session.preferredInput?.portName
            ?? "Audio Input"
        let rate = format.sampleRate
        log.info("Opened \(name, privacy: .public) at \(rate, format: .fixed(precision: 0)) Hz, \(bufferFrames) frames")
        return CaptureStatus(deviceName: name, sampleRate: rate, bufferFrames: bufferFrames)
    }

    func stop() {
        guard runningDeviceID != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        runningDeviceID = nil
    }

    private static func prepareSession(_ session: AVAudioSession) {
        try? configureSession(session)
        try? session.setActive(true, options: [])
    }

    private static func configureSession(_ session: AVAudioSession) throws {
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(1_024.0 / 48_000.0)
        } catch {
            throw CaptureError.cannotConfigure(error.localizedDescription)
        }
    }

    private func consume(buffer: AVAudioPCMBuffer, channels: Int) {
        guard let channelData = buffer.floatChannelData, channels >= 2 else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        if buffer.stride == 1 {
            var remaining = frames
            var offset = 0
            let left = channelData[0]
            let right = channelData[1]
            while remaining > 0 {
                let count = min(remaining, scratchFrames)
                for frame in 0..<count {
                    scratch[frame * 2] = left[offset + frame]
                    scratch[frame * 2 + 1] = right[offset + frame]
                }
                ring.writeInterleaved(scratch, frameCount: count)
                offset += count
                remaining -= count
            }
        } else {
            ring.writeInterleaved(channelData[0], frameCount: frames)
        }
    }
    #endif
}

#if os(macOS)
private extension AudioCapture {
    private func consume(_ inputData: UnsafePointer<AudioBufferList>) {
        let count = Int(inputData.pointee.mNumberBuffers)
        guard count > 0 else { return }
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) ?? 8
        let start = UnsafeRawPointer(inputData).advanced(by: offset).assumingMemoryBound(to: AudioBuffer.self)
        let buffers = UnsafeBufferPointer(start: start, count: count)
        let first = buffers[0]
        guard let data = first.mData else { return }

        if count == 1, first.mNumberChannels >= 2 {
            let channels = Int(first.mNumberChannels)
            let sampleBytes = sampleKind == .float32 ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
            let frameBytes = sampleBytes * channels
            guard frameBytes > 0 else { return }
            let frames = Int(first.mDataByteSize) / frameBytes
            if sampleKind == .float32, channels == 2 {
                ring.writeInterleaved(data.assumingMemoryBound(to: Float.self), frameCount: frames)
            } else if sampleKind == .float32 {
                writePlanarFloat(data.assumingMemoryBound(to: Float.self), frames: frames, channels: channels)
            } else {
                writeInt16(data.assumingMemoryBound(to: Int16.self), frames: frames, channels: channels)
            }
            return
        }

        guard count >= 2, first.mNumberChannels == 1, buffers[1].mNumberChannels == 1, let rightData = buffers[1].mData else {
            return
        }
        let sampleBytes = sampleKind == .float32 ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
        let frames = min(Int(first.mDataByteSize), Int(buffers[1].mDataByteSize)) / sampleBytes
        if sampleKind == .float32 {
            interleave(
                data.assumingMemoryBound(to: Float.self),
                rightData.assumingMemoryBound(to: Float.self),
                frames: frames
            )
        } else {
            interleaveInt16(
                data.assumingMemoryBound(to: Int16.self),
                rightData.assumingMemoryBound(to: Int16.self),
                frames: frames
            )
        }
    }

    private func writePlanarFloat(_ source: UnsafePointer<Float>, frames: Int, channels: Int) {
        var remaining = frames
        var cursor = source
        while remaining > 0 {
            let count = min(remaining, scratchFrames)
            for frame in 0..<count {
                scratch[frame * 2] = cursor[frame * channels]
                scratch[frame * 2 + 1] = cursor[frame * channels + 1]
            }
            ring.writeInterleaved(scratch, frameCount: count)
            cursor = cursor.advanced(by: count * channels)
            remaining -= count
        }
    }

    private func writeInt16(_ source: UnsafePointer<Int16>, frames: Int, channels: Int) {
        var remaining = frames
        var cursor = source
        while remaining > 0 {
            let count = min(remaining, scratchFrames)
            for frame in 0..<count {
                scratch[frame * 2] = Float(cursor[frame * channels]) / 32_768
                scratch[frame * 2 + 1] = Float(cursor[frame * channels + 1]) / 32_768
            }
            ring.writeInterleaved(scratch, frameCount: count)
            cursor = cursor.advanced(by: count * channels)
            remaining -= count
        }
    }

    private func interleave(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, frames: Int) {
        var remaining = frames
        var leftCursor = left
        var rightCursor = right
        while remaining > 0 {
            let count = min(remaining, scratchFrames)
            for frame in 0..<count {
                scratch[frame * 2] = leftCursor[frame]
                scratch[frame * 2 + 1] = rightCursor[frame]
            }
            ring.writeInterleaved(scratch, frameCount: count)
            leftCursor = leftCursor.advanced(by: count)
            rightCursor = rightCursor.advanced(by: count)
            remaining -= count
        }
    }

    private func interleaveInt16(_ left: UnsafePointer<Int16>, _ right: UnsafePointer<Int16>, frames: Int) {
        var remaining = frames
        var leftCursor = left
        var rightCursor = right
        while remaining > 0 {
            let count = min(remaining, scratchFrames)
            for frame in 0..<count {
                scratch[frame * 2] = Float(leftCursor[frame]) / 32_768
                scratch[frame * 2 + 1] = Float(rightCursor[frame]) / 32_768
            }
            ring.writeInterleaved(scratch, frameCount: count)
            leftCursor = leftCursor.advanced(by: count)
            rightCursor = rightCursor.advanced(by: count)
            remaining -= count
        }
    }

    private struct OpenedFormat {
        var kind: SampleKind
    }

    private func streamFormat(_ id: AudioDeviceID) throws -> OpenedFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &format)
        guard status == noErr else { throw CaptureError.cannotStart(status) }
        guard format.mChannelsPerFrame >= 2 else { throw CaptureError.noStereoInput }
        let flags = format.mFormatFlags
        if flags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 {
            return OpenedFormat(kind: .float32)
        }
        if flags & kAudioFormatFlagIsSignedInteger != 0, format.mBitsPerChannel == 16 {
            return OpenedFormat(kind: .int16)
        }
        throw CaptureError.unsupportedFormat("\(format.mBitsPerChannel)-bit flags \(flags)")
    }

    private func lockSampleRate(_ id: AudioDeviceID) throws {
        var rate = Float64(48_000)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, size, &rate)
        if status != noErr {
            log.error("Could not lock 48 kHz (\(status)). Continuing at the current rate.")
        }
    }

    private func setBufferFrames(_ id: AudioDeviceID, preferred: UInt32) -> Int {
        var rangeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange(mMinimum: 512, mMaximum: 1_024)
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        if AudioObjectGetPropertyData(id, &rangeAddress, 0, nil, &rangeSize, &range) == noErr {
            let low = UInt32(range.mMinimum.rounded(.up))
            let high = UInt32(max(range.mMaximum.rounded(.down), Double(low)))
            let clamped = min(max(preferred, low), high)
            var frames = clamped
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectSetPropertyData(id, &address, 0, nil, size, &frames)
            if status != noErr {
                log.error("Could not set buffer to \(clamped) frames (\(status)).")
            }
        }
        return Int(nominalBufferFrames(id))
    }

    private func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(48_000)
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return rate
    }

    private func nominalBufferFrames(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var frames: UInt32 = 512
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &frames)
        return frames
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        let ids = UnsafeMutablePointer<AudioDeviceID>.allocate(capacity: max(count, 1))
        defer { ids.deallocate() }
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, ids) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: ids, count: count))
    }

    private static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let count = Int(list.pointee.mNumberBuffers)
        guard count > 0 else { return 0 }
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) ?? 8
        let buffers = UnsafeBufferPointer(
            start: raw.advanced(by: offset).assumingMemoryBound(to: AudioBuffer.self),
            count: count
        )
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return "Audio Input" }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<CFString>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return "Audio Input" }
        return raw.load(as: Unmanaged<CFString>.self).takeRetainedValue() as String
    }
}
#endif
