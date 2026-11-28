import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import os

// Native CoreAudio microphone capture helper, isolated in its own process.
//
// Speaks the exact same protocol as mic_capture.py:
//   Usage: ctrlspeak-mic <samplerate> <channels> <blocksize> [device | --standby]
//   stdout: raw little-endian float32 PCM, blocksize * channels values per block.
//   stderr: "standby" (when launched with --standby), then "ready" or "open-failed: ...".
//   stdin:  in --standby mode, one line "open <device>" ("-" for system default).
//
// Owning the stream in a dedicated child process keeps CoreAudio HAL teardown
// deadlocks out of the parent service: releasing the microphone is SIGKILL.
// Doing it in native Swift + CoreAudio avoids a permanent second Python+NumPy+
// PortAudio standby process (~35 MB RSS) and PortAudio's full device rescan on
// every recording start.

private func writeStderr(_ line: String) {
    let data = Array((line + "\n").utf8)
    data.withUnsafeBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return }
        var offset = 0
        while offset < ptr.count {
            let n = Darwin.write(STDERR_FILENO, base.advanced(by: offset), ptr.count - offset)
            if n <= 0 {
                if errno == EINTR { continue }
                return
            }
            offset += n
        }
    }
}

private func writeAllStdout(_ buffer: UnsafeRawPointer, count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let n = Darwin.write(STDOUT_FILENO, buffer.advanced(by: offset), count - offset)
        if n < 0 {
            if errno == EINTR { continue }
            return false
        }
        if n == 0 { return false }
        offset += n
    }
    return true
}

private func deviceName(_ deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
    }
    guard status == noErr, let cf = unmanaged?.takeRetainedValue() else { return nil }
    return cf as String
}

private func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
          size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, abl) == noErr else {
        return 0
    }
    return UnsafeMutableAudioBufferListPointer(abl).reduce(0) { $0 + Int($1.mNumberChannels) }
}

private func allInputDevices() -> [(id: AudioDeviceID, name: String)] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    ) == noErr, size > 0 else { return [] }

    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
    ) == noErr else { return [] }

    var result: [(id: AudioDeviceID, name: String)] = []
    for id in ids where inputChannelCount(id) > 0 {
        if let name = deviceName(id) {
            result.append((id: id, name: name))
        }
    }
    return result
}

private func defaultInputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

private func resolveInputDevice(_ spec: String?) -> AudioDeviceID? {
    guard let spec, !spec.isEmpty, spec != "-" else {
        return defaultInputDevice()
    }
    let devices = allInputDevices()
    if let exact = devices.first(where: { $0.name == spec }) {
        return exact.id
    }
    let lowered = spec.lowercased()
    if let match = devices.first(where: { $0.name.lowercased().contains(lowered) }) {
        return match.id
    }
    return defaultInputDevice()
}

/// Bounded lock-protected FIFO of fixed-size PCM blocks so the CoreAudio IO
/// thread never blocks on pipe writes.
private final class BlockQueue {
    private let capacity: Int
    private var lock = os_unfair_lock_s()
    private var items: [[Float]] = []
    private var head = 0
    private var closed = false
    private let sem = DispatchSemaphore(value: 0)

    init(capacity: Int = 256) {
        self.capacity = capacity
        self.items.reserveCapacity(capacity)
    }

    func push(_ block: [Float]) {
        os_unfair_lock_lock(&lock)
        let activeCount = items.count - head
        if activeCount < capacity && !closed {
            items.append(block)
            os_unfair_lock_unlock(&lock)
            sem.signal()
            return
        }
        os_unfair_lock_unlock(&lock)
    }

    func pop() -> [Float]? {
        sem.wait()
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if head < items.count {
            let block = items[head]
            items[head] = []
            head += 1
            if head >= 64 && head * 2 >= items.count {
                items.removeFirst(head)
                head = 0
            }
            return block
        }
        return nil
    }

    func close() {
        os_unfair_lock_lock(&lock)
        closed = true
        os_unfair_lock_unlock(&lock)
        sem.signal()
    }
}

private final class CaptureContext {
    let audioUnit: AudioUnit
    let converter: AudioConverterRef
    let hwChannels: UInt32
    let targetChannels: UInt32
    let blockSamples: Int
    let queue: BlockQueue

    // Reusable scratch buffers used exclusively on the real-time IO thread.
    var renderCapacityFrames: UInt32 = 0
    var renderStorage: UnsafeMutablePointer<Float>?
    var convOutStorage: UnsafeMutablePointer<Float>
    var convOutCapacityFrames: UInt32 = 4096

    // Source pointer/count for AudioConverterFillComplexBuffer callback.
    var currentInputPtr: UnsafeMutableRawPointer?
    var currentInputBytes: UInt32 = 0
    var currentInputFrames: UInt32 = 0
    var inputConsumed: Bool = false

    // Accumulation buffer until a full blockSamples chunk is ready.
    var accum: [Float] = []

    init(
        audioUnit: AudioUnit,
        converter: AudioConverterRef,
        hwChannels: UInt32,
        targetChannels: UInt32,
        blockSamples: Int,
        queue: BlockQueue
    ) {
        self.audioUnit = audioUnit
        self.converter = converter
        self.hwChannels = hwChannels
        self.targetChannels = targetChannels
        self.blockSamples = blockSamples
        self.queue = queue
        self.convOutStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: Int(convOutCapacityFrames * targetChannels)
        )
        self.accum.reserveCapacity(blockSamples * 2)
    }

    deinit {
        renderStorage?.deallocate()
        convOutStorage.deallocate()
    }

    func ensureRenderBuffer(frames: UInt32) -> UnsafeMutablePointer<Float> {
        if frames > renderCapacityFrames || renderStorage == nil {
            renderStorage?.deallocate()
            let cap = max(frames, 2048)
            renderStorage = UnsafeMutablePointer<Float>.allocate(capacity: Int(cap * hwChannels))
            renderCapacityFrames = cap
        }
        return renderStorage!
    }
}

private let converterInputProc: AudioConverterComplexInputDataProc = {
    _, ioNumberDataPackets, ioData, _, inUserData in
    guard let raw = inUserData else {
        ioNumberDataPackets.pointee = 0
        return -1
    }
    let ctx = Unmanaged<CaptureContext>.fromOpaque(raw).takeUnretainedValue()
    if ctx.inputConsumed || ctx.currentInputFrames == 0 {
        ioNumberDataPackets.pointee = 0
        return noErr
    }
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = ctx.hwChannels
    ioData.pointee.mBuffers.mDataByteSize = ctx.currentInputBytes
    ioData.pointee.mBuffers.mData = ctx.currentInputPtr
    ioNumberDataPackets.pointee = ctx.currentInputFrames
    ctx.inputConsumed = true
    return noErr
}

private let halInputCallback: AURenderCallback = {
    inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
    let ctx = Unmanaged<CaptureContext>.fromOpaque(inRefCon).takeUnretainedValue()
    let renderPtr = ctx.ensureRenderBuffer(frames: inNumberFrames)
    let byteSize = inNumberFrames * ctx.hwChannels * UInt32(MemoryLayout<Float>.size)

    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: ctx.hwChannels,
            mDataByteSize: byteSize,
            mData: UnsafeMutableRawPointer(renderPtr)
        )
    )

    let renderStatus = AudioUnitRender(
        ctx.audioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList
    )
    guard renderStatus == noErr else { return renderStatus }

    ctx.currentInputPtr = UnsafeMutableRawPointer(renderPtr)
    ctx.currentInputBytes = bufferList.mBuffers.mDataByteSize
    ctx.currentInputFrames = inNumberFrames
    ctx.inputConsumed = false

    let outBytes = ctx.convOutCapacityFrames * ctx.targetChannels * UInt32(MemoryLayout<Float>.size)
    while true {
        var outPackets = ctx.convOutCapacityFrames
        var outList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: ctx.targetChannels,
                mDataByteSize: outBytes,
                mData: UnsafeMutableRawPointer(ctx.convOutStorage)
            )
        )
        let status = AudioConverterFillComplexBuffer(
            ctx.converter,
            converterInputProc,
            inRefCon,
            &outPackets,
            &outList,
            nil
        )
        if outPackets > 0 {
            let count = Int(outPackets * ctx.targetChannels)
            let buf = UnsafeBufferPointer(start: ctx.convOutStorage, count: count)
            ctx.accum.append(contentsOf: buf)
            while ctx.accum.count >= ctx.blockSamples {
                let block = Array(ctx.accum[0..<ctx.blockSamples])
                ctx.accum.removeFirst(ctx.blockSamples)
                ctx.queue.push(block)
            }
        }
        if status != noErr || outPackets == 0 || ctx.inputConsumed {
            break
        }
    }
    return noErr
}

private struct MicError: Error {
    let message: String
}

private func makeHALInputUnit() -> Result<AudioUnit, MicError> {
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )
    guard let comp = AudioComponentFindNext(nil, &desc) else {
        return .failure(MicError(message: "HAL output component not found"))
    }

    var maybeUnit: AudioUnit?
    var status = AudioComponentInstanceNew(comp, &maybeUnit)
    guard status == noErr, let unit = maybeUnit else {
        return .failure(MicError(message: "AudioComponentInstanceNew failed (\(status))"))
    }

    // Enable input on bus 1, disable output on bus 0 (no device opened yet).
    var enableIO: UInt32 = 1
    status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size)
    )
    guard status == noErr else {
        return .failure(MicError(message: "enable input failed (\(status))"))
    }

    var disableIO: UInt32 = 0
    status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout<UInt32>.size)
    )
    guard status == noErr else {
        return .failure(MicError(message: "disable output failed (\(status))"))
    }
    return .success(unit)
}

private func openAndRun(
    sampleRate: Double,
    channels: UInt32,
    blocksize: Int,
    deviceSpec: String?,
    warmUnit: AudioUnit? = nil
) -> Int32 {
    guard let deviceID = resolveInputDevice(deviceSpec) else {
        writeStderr("open-failed: no input device available")
        return 1
    }

    let unit: AudioUnit
    if let warmUnit {
        unit = warmUnit
    } else {
        switch makeHALInputUnit() {
        case .success(let created):
            unit = created
        case .failure(let err):
            writeStderr("open-failed: \(err.message)")
            return 1
        }
    }

    // Select the requested input device.
    var dev = deviceID
    var status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else {
        writeStderr("open-failed: set input device failed (\(status))")
        return 1
    }

    // Inspect hardware native format on bus 1 input scope.
    var hwFormat = AudioStreamBasicDescription()
    var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    status = AudioUnitGetProperty(
        unit, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input, 1, &hwFormat, &propSize
    )
    guard status == noErr, hwFormat.mSampleRate > 0, hwFormat.mChannelsPerFrame > 0 else {
        writeStderr("open-failed: could not read hardware format (\(status))")
        return 1
    }

    let hwChannels = hwFormat.mChannelsPerFrame
    var clientFormat = AudioStreamBasicDescription(
        mSampleRate: hwFormat.mSampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: hwChannels * UInt32(MemoryLayout<Float>.size),
        mFramesPerPacket: 1,
        mBytesPerFrame: hwChannels * UInt32(MemoryLayout<Float>.size),
        mChannelsPerFrame: hwChannels,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    status = AudioUnitSetProperty(
        unit, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output, 1, &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    )
    guard status == noErr else {
        writeStderr("open-failed: set client format failed (\(status))")
        return 1
    }

    var targetFormat = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: channels * UInt32(MemoryLayout<Float>.size),
        mFramesPerPacket: 1,
        mBytesPerFrame: channels * UInt32(MemoryLayout<Float>.size),
        mChannelsPerFrame: channels,
        mBitsPerChannel: 32,
        mReserved: 0
    )

    var maybeConverter: AudioConverterRef?
    status = AudioConverterNew(&clientFormat, &targetFormat, &maybeConverter)
    guard status == noErr, let converter = maybeConverter else {
        writeStderr("open-failed: AudioConverterNew failed (\(status))")
        return 1
    }

    let queue = BlockQueue(capacity: 256)
    let ctx = CaptureContext(
        audioUnit: unit,
        converter: converter,
        hwChannels: hwChannels,
        targetChannels: channels,
        blockSamples: blocksize * Int(channels),
        queue: queue
    )
    let unmanagedCtx = Unmanaged.passRetained(ctx)

    var callbackStruct = AURenderCallbackStruct(
        inputProc: halInputCallback,
        inputProcRefCon: unmanagedCtx.toOpaque()
    )
    status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_SetInputCallback,
        kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
    )
    guard status == noErr else {
        unmanagedCtx.release()
        writeStderr("open-failed: set input callback failed (\(status))")
        return 1
    }

    status = AudioUnitInitialize(unit)
    guard status == noErr else {
        unmanagedCtx.release()
        writeStderr("open-failed: AudioUnitInitialize failed (\(status))")
        return 1
    }

    status = AudioOutputUnitStart(unit)
    guard status == noErr else {
        unmanagedCtx.release()
        writeStderr("open-failed: AudioOutputUnitStart failed (\(status))")
        return 1
    }

    writeStderr("ready")

    // Pump PCM blocks from the bounded queue to stdout until the pipe closes.
    while let block = queue.pop() {
        let ok = block.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            return writeAllStdout(base, count: bytes.count)
        }
        if !ok { break }
    }
    return 0
}

// Ignore SIGPIPE so a closed parent pipe returns EPIPE cleanly from write().
signal(SIGPIPE, SIG_IGN)

let args = CommandLine.arguments
if args.count == 2 && args[1] == "--list" {
    for device in allInputDevices() {
        let line = device.name + "\n"
        _ = line.withCString { ptr in
            writeAllStdout(ptr, count: strlen(ptr))
        }
    }
    exit(0)
}

guard args.count >= 4,
      let sampleRate = Double(args[1]), sampleRate > 0,
      let channels = UInt32(args[2]), channels > 0,
      let blocksize = Int(args[3]), blocksize > 0 else {
    writeStderr("open-failed: usage: ctrlspeak-mic <samplerate> <channels> <blocksize> [device|--standby] | --list")
    exit(2)
}

let deviceArg: String? = args.count > 4 ? args[4] : "-"

let resolvedDeviceSpec: String?
var prewarmedUnit: AudioUnit? = nil
if deviceArg == "--standby" {
    // Establish the CoreAudio HAL connection and HALOutput AudioUnit ahead of
    // time (no device selected or started, so the mic indicator stays off).
    if case .success(let unit) = makeHALInputUnit() {
        prewarmedUnit = unit
    }
    _ = defaultInputDevice()
    writeStderr("standby")
    guard let line = readLine() else {
        exit(0) // EOF: service exited before needing capture
    }
    guard line.hasPrefix("open") else {
        exit(0)
    }
    let spec = line.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
    resolvedDeviceSpec = (spec.isEmpty || spec == "-") ? nil : spec
} else {
    resolvedDeviceSpec = (deviceArg == nil || deviceArg == "" || deviceArg == "-") ? nil : deviceArg
}

exit(openAndRun(
    sampleRate: sampleRate,
    channels: channels,
    blocksize: blocksize,
    deviceSpec: resolvedDeviceSpec,
    warmUnit: prewarmedUnit
))
