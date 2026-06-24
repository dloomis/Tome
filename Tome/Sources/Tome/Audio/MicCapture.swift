@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let _audioLevel = AudioLevel()
    private let _error = SyncString()

    /// Optional crash-resilient WAV writer for retaining the mic track. Created in
    /// `bufferStream` when a `recordOutputURL` is provided, written from the tap
    /// callback, closed in `stop()`.
    private let _recordWriter = OSAllocatedUnfairLock<WAVStreamWriter?>(uncheckedState: nil)

    /// Wall-clock time of the first buffer delivered by the tap. Used by the
    /// post-session mixer to align the mic track to the session start. Persisted
    /// across `stop()` so the engine can snapshot it at teardown.
    private let _firstSampleTime = OSAllocatedUnfairLock<Date?>(uncheckedState: nil)
    var firstSampleTime: Date? { _firstSampleTime.withLock { $0 } }

    var audioLevel: Float { _audioLevel.value }
    var captureError: String? { _error.value }

    /// - Parameter recordOutputURL: when non-nil, the mic track is also written to a
    ///   WAV at this path (float32 mono) for post-session retention. The first input
    ///   channel only is captured for multi-channel devices.
    func bufferStream(deviceID: AudioDeviceID? = nil, recordOutputURL: URL? = nil) -> AsyncStream<AVAudioPCMBuffer> {
        let level = _audioLevel
        let errorHolder = _error

        return AsyncStream { continuation in
            errorHolder.value = nil

            diagLog("[MIC-1] bufferStream called, deviceID=\(String(describing: deviceID))")

            // Set input device before accessing inputNode format
            if let id = deviceID {
                let inputNode = self.engine.inputNode
                guard let audioUnit = inputNode.audioUnit else {
                    // The input node exposes no audio unit (no HAL input, device in
                    // a bad state). Surface it instead of force-unwrap-crashing.
                    let msg = "Microphone input is unavailable — can't select device \(id)."
                    diagLog("[MIC-2-FAIL] \(msg)")
                    errorHolder.value = msg
                    continuation.finish()
                    return
                }
                var devID = id
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                diagLog("[MIC-2] setInputDevice status=\(status) (0=ok)")
                // Surface a real failure to the UI — historically the silent fallback
                // to "system default" hid disconnected-USB-mic cases entirely.
                guard status == noErr else {
                    let msg = "Failed to set mic device \(id): OSStatus \(status)"
                    diagLog("[MIC-2-FAIL] \(msg)")
                    errorHolder.value = msg
                    continuation.finish()
                    return
                }
            } else {
                diagLog("[MIC-2] no deviceID, using system default")
            }

            let inputNode = self.engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            diagLog("[MIC-3] inputNode format: sr=\(format.sampleRate) ch=\(format.channelCount) interleaved=\(format.isInterleaved) commonFormat=\(format.commonFormat.rawValue)")

            guard format.sampleRate > 0 && format.channelCount > 0 else {
                let msg = "Invalid audio format: sr=\(format.sampleRate) ch=\(format.channelCount)"
                diagLog("[MIC-3-FAIL] \(msg)")
                errorHolder.value = msg
                continuation.finish()
                return
            }

            guard let tapFormat = AVAudioFormat(
                standardFormatWithSampleRate: format.sampleRate,
                channels: format.channelCount
            ) else {
                let msg = "Failed to build tap format from input format"
                diagLog("[MIC-4-FAIL] \(msg)")
                errorHolder.value = msg
                continuation.finish()
                return
            }

            diagLog("[MIC-4] tapFormat: sr=\(tapFormat.sampleRate) ch=\(tapFormat.channelCount)")

            // Open the retention WAV writer (mono float32) before the tap fires.
            self._firstSampleTime.withLock { $0 = nil }
            self._recordWriter.withLock { writer in
                writer?.close()
                writer = nil
                guard let url = recordOutputURL else { return }
                do {
                    writer = try WAVStreamWriter(url: url, sampleRate: tapFormat.sampleRate, channels: 1)
                } catch {
                    diagLog("[MIC-WAV-FAIL] could not open writer at \(url.path): \(error)")
                }
            }

            let recordWriter = self._recordWriter
            let firstSampleTime = self._firstSampleTime

            var tapCallCount = 0
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
                tapCallCount += 1
                let rms = Self.normalizedRMS(from: buffer)
                level.value = min(rms * 25, 1.0)

                if tapCallCount <= 5 || tapCallCount % 100 == 0 {
                    diagLog("[MIC-6] tap #\(tapCallCount): frames=\(buffer.frameLength) rms=\(rms) level=\(level.value)")
                }

                firstSampleTime.withLock { if $0 == nil { $0 = Date() } }
                recordWriter.withLock { try? $0?.write(buffer) }

                continuation.yield(buffer)
            }

            diagLog("[MIC-5] tap installed, preparing engine...")

            do {
                self.engine.prepare()
                diagLog("[MIC-7] engine prepared, starting...")
                try self.engine.start()
                diagLog("[MIC-8] engine started successfully, isRunning=\(self.engine.isRunning)")
            } catch {
                let msg = "Mic failed: \(error.localizedDescription)"
                print("[MIC-8-FAIL] \(msg)")
                errorHolder.value = msg
                continuation.finish()
            }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        _audioLevel.value = 0
        // Flush + finalize the retention WAV. firstSampleTime is intentionally
        // preserved so the engine can snapshot it after stop.
        _recordWriter.withLock { writer in
            writer?.close()
            writer = nil
        }
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(max(buffer.format.channelCount, 1))
        guard frameLength > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return channelData[0][(frame * stride) + channel]
                }
                return channelData[channel][frame]
            }
        }

        if let channelData = buffer.int16ChannelData {
            let scale: Float = 1 / Float(Int16.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return Float(channelData[0][(frame * stride) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        if let channelData = buffer.int32ChannelData {
            let scale: Float = 1 / Float(Int32.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return Float(channelData[0][(frame * stride) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        return 0
    }

    private static func rms(
        frameLength: Int,
        channelCount: Int,
        sampleAt: (_ frame: Int, _ channel: Int) -> Float
    ) -> Float {
        var sum: Float = 0

        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                let s = sampleAt(frame, channel)
                sum += s * s
            }
        }

        let sampleCount = Float(frameLength * channelCount)
        return sampleCount > 0 ? sqrt(sum / sampleCount) : 0
    }

    // MARK: - List available input devices

    static func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [(id: AudioDeviceID, name: String)] = []

        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var bufferListSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &bufferListSize)
            guard status == noErr, bufferListSize > 0 else { continue }

            // AudioBufferList is a variable-length struct: its C definition carries a
            // single AudioBuffer inline, but a device with multiple input streams reports
            // a `bufferListSize` covering mNumberBuffers buffers. Allocating one
            // `AudioBufferList` (room for a single buffer) and then letting CoreAudio
            // write the full `bufferListSize` overflows the heap. Allocate the exact
            // reported byte count instead.
            let bufferListPtr = UnsafeMutableRawPointer.allocate(
                byteCount: Int(bufferListSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { bufferListPtr.deallocate() }
            status = AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &bufferListSize, bufferListPtr)
            guard status == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(
                bufferListPtr.assumingMemoryBound(to: AudioBufferList.self)
            )
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
            guard status == noErr else { continue }

            result.append((id: deviceID, name: name as String))
        }

        return result
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        return status == noErr ? uid as String : nil
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }
}

// Thread-safe audio level
final class AudioLevel: @unchecked Sendable {
    private var _value: Float = 0
    private let lock = NSLock()

    var value: Float {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// Thread-safe optional string
final class SyncString: @unchecked Sendable {
    private var _value: String?
    private let lock = NSLock()

    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
