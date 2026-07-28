@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import ObjCExceptionGuard
import os

/// How a capture bind failed. `setupFailed` is the classic synchronous
/// failure (no HAL input, device-set error, tap format exception, start
/// throw); the other two are the 2026-07-25 hang fix — the bind never
/// returned within the deadline, or wasn't attempted because an earlier
/// HAL call is still stuck.
enum CaptureBindError: Error, Equatable {
    case setupFailed(String)
    case timedOut
    case halWedged
}

final class MicCapture: @unchecked Sendable {
    /// Crash-resilient WAV writer retaining the mic track, plus (when an
    /// adopted recording's on-disk rate differs from the newly-attached
    /// device's native rate) a converter resampling to the file's rate
    /// before each write.
    private struct RetentionWriter {
        let writer: WAVStreamWriter
        let converter: AVAudioConverter?
    }

    /// Recreated on every `bufferStream` call. AVAudioEngine caches its input node's
    /// hardware format; reusing one engine across device changes left every later
    /// device reporting the previous device's format (observed: all inputs stuck at
    /// AirPods-HFP 24 kHz / 3 ch after one AirPods session, so no device could
    /// record until app relaunch). A fresh engine re-reads the real format each
    /// time. Only touched from the HAL queue (2026-07-25 hang fix — bind and
    /// teardown both run there; the main actor must never wait on a HAL call).
    private var engine = AVAudioEngine()
    private let _audioLevel = AudioLevel()
    private let _error = SyncString()

    /// Optional crash-resilient WAV writer for retaining the mic track. Created in
    /// `bufferStream` when a `recordOutputURL` is provided, written from the tap
    /// callback, closed in `stop()`.
    private let _retentionWriter = OSAllocatedUnfairLock<RetentionWriter?>(uncheckedState: nil)

    /// Wall-clock time of the first buffer delivered by the tap. Used by the
    /// post-session mixer to align the mic track to the session start. Persisted
    /// across `stop()` so the engine can snapshot it at teardown.
    private let _firstSampleTime = OSAllocatedUnfairLock<Date?>(uncheckedState: nil)
    var firstSampleTime: Date? { _firstSampleTime.withLock { $0 } }

    /// Back-date the session-start anchor to `anchor` when this capture adopted
    /// a WAV another source began (SCK→device adoption): the post-session mixer
    /// aligns the track at `firstSampleTime`, and an adopted file's audio starts
    /// at the ORIGINAL source's first sample, not this bind's. Only ever moves
    /// the anchor EARLIER — the tap's own first buffer must never be overwritten
    /// with a later date.
    func seedFirstSampleTime(_ anchor: Date) {
        _firstSampleTime.withLock { current in
            if current == nil || anchor < current! { current = anchor }
        }
    }

    /// Wall-clock time of the most recent buffer delivered by the TAP while
    /// capture is active; `nil` when not capturing or before the first buffer.
    /// The engine's watchdog reads this to detect a mic that silently stopped
    /// delivering (device pulled, HAL wedge) — AVAudioEngine reports no error in
    /// those cases, mirroring `SystemAudioCapture.lastSampleTime`. Written ONLY
    /// by the tap callback: the watchdog treats it as authoritative evidence of
    /// real audio (a stall may only clear on this, never on the start seed below).
    private let _lastSampleTime = OSAllocatedUnfairLock<Date?>(uncheckedState: nil)
    var lastSampleTime: Date? { _lastSampleTime.withLock { $0 } }

    /// True once the tap has delivered at least one buffer with a non-zero
    /// sample since the last `bufferStream` entry. A real microphone's noise
    /// floor is never exactly zero, so a delivering-but-all-zero stream is the
    /// signature of an unfed virtual device (an audio router's mix whose app is
    /// not running — Wave Link's devices stay enumerable while it's closed) or
    /// a hard-muted input. The engine reads this to warn instead of silently
    /// recording zeros for a whole meeting.
    private let _sawNonzeroSample = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
    var sawNonzeroSample: Bool { _sawNonzeroSample.withLock { $0 } }

    /// Wall-clock time capture was (re)started, seeded on successful engine
    /// start. The watchdog uses it as the stall baseline while the tap hasn't
    /// delivered yet — so a device that never sends a single buffer still alarms
    /// ~threshold seconds after start — but it can never CLEAR a stall.
    private let _captureStartTime = OSAllocatedUnfairLock<Date?>(uncheckedState: nil)
    var captureStartTime: Date? { _captureStartTime.withLock { $0 } }

    /// Content telemetry for this capture: audible-buffer and write-failure
    /// counts, reset on every `bufferStream` entry. Exists so a device-backed
    /// system leg (`TranscriptionEngine.systemDeviceCapture`) reports the same
    /// numbers the SCK leg does — the 60s no-audible warning, the end-of-session
    /// note, and `SessionHandle.wavWriteErrorCount` all read them through the
    /// engine's mode-routed accessors.
    private let _content = CaptureContentCounters()
    var audibleBufferCount: Int { _content.audibleBufferCount }
    var writeErrorCount: Int { _content.writeErrorCount }

    var audioLevel: Float { _audioLevel.value }
    var captureError: String? { _error.value }

    /// Hold a retiring engine for 15s before release. See the retire call site in
    /// `bufferStream` — AVFAudio's async device-change callbacks reference the
    /// engine that registered them, and deallocating it while they're queued is a
    /// use-after-free inside the framework. The task's capture of `old` IS the
    /// mechanism: release happens when the closure completes, long after any
    /// in-flight AVAudioIOUnit-queue blocks have drained.
    private static func retire(_ old: AVAudioEngine) {
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(15))
            _ = old
            diagLog("[MIC-RETIRE] released a retired engine")
        }
    }

    /// Engines whose HAL call timed out are parked for the PROCESS LIFETIME —
    /// no 15s release. There is no upper bound on when a wedged driver lets go
    /// of its references, so deallocating one of these risks the same
    /// use-after-free `retire(_:)` guards against, with unbounded exposure.
    /// The cost is one dead AVAudioEngine per wedge incident — negligible.
    private static let permanentlyRetired = OSAllocatedUnfairLock<[AVAudioEngine]>(uncheckedState: [])

    private static func retireForever(_ old: AVAudioEngine) {
        let count = permanentlyRetired.withLock { retired -> Int in
            retired.append(old)
            return retired.count
        }
        diagLog("[MIC-RETIRE] parked a timed-out engine for the process lifetime (\(count) total)")
    }

    /// Fired when the running engine posts `AVAudioEngineConfigurationChange` —
    /// Apple's contract is that the engine STOPS on audio-route/graph changes
    /// (Bluetooth connect, HFP↔A2DP renegotiation, device unplug) and the app
    /// must bring it back up. Without this, the tap dies silently and only the
    /// 15s watchdog notices (observed 2026-07-06: AirPods connecting killed a
    /// running Brio tap with zero errors). The engine layer debounces and
    /// rebuilds on the CURRENT device.
    var onConfigurationChange: (@Sendable () -> Void)?

    /// Observer token for the current engine's configuration-change notification.
    private let _configObserver = OSAllocatedUnfairLock<NSObjectProtocol?>(uncheckedState: nil)

    /// Continuation of the currently-live buffer stream. `stop()` FINISHES it so
    /// the consuming `StreamingTranscriber` drains buffered audio and flushes the
    /// in-progress utterance — before this existed the stream simply went quiet
    /// and the engine had to cancel the consumer task, which poisoned the
    /// stop-time ASR flush (cancelled tasks make FluidAudio/WhisperKit throw).
    private let _streamContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(uncheckedState: nil)

    private func removeConfigObserver() {
        _configObserver.withLock { token in
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
    }

    /// HAL property listener registered directly on the RESOLVED capture device
    /// (not the system object) so we synthesize the missing notification in the
    /// AirPods cold-start bug: `engine.start()` succeeds against the pre-switch
    /// A2DP 48 kHz format, the profile then flips to HFP 24 kHz, and the tap
    /// delivers nothing — with NO error and (field-observed) NO
    /// AVAudioEngineConfigurationChange. Listening for the device's own
    /// `NominalSampleRate` / `StreamConfiguration` changes catches that flip and
    /// feeds the SAME debounced rebuild path the engine notification would.
    /// Stored so we can remove it in `stop()` and before re-registering on a
    /// rebuild (bufferStream is re-entered on rebuild). Mirrors the
    /// default-device-listener add/remove pattern in TranscriptionEngine. Held as
    /// a plain property (not a lock) because — like `engine` — it is only
    /// touched from the HAL queue (register in the bind, remove in the stop
    /// teardown), and `AudioObjectPropertyListenerBlock` is non-Sendable so it
    /// can't cross a lock's `@Sendable` closure boundary.
    private var _halListener: (block: AudioObjectPropertyListenerBlock, deviceID: AudioDeviceID)?

    /// The property selectors we watch on the resolved device. NominalSampleRate
    /// is the A2DP↔HFP rate flip itself (48 k↔24 k); StreamConfiguration covers a
    /// channel-count change on the same flip (stereo A2DP → multi-ch HFP).
    private static let halWatchedAddresses: [AudioObjectPropertyAddress] = [
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        ),
    ]

    private func removeHALListener() {
        guard let (block, deviceID) = _halListener else { return }
        for var address in Self.halWatchedAddresses {
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        }
        _halListener = nil
    }

    /// Register the HAL fast-path listener on `deviceID`. Idempotent: removes any
    /// prior registration first (bufferStream re-enters on rebuild). The handler
    /// deliberately routes through `onConfigurationChange` — the SAME debounced
    /// `scheduleMicRebuild` path — so its ground-truth gate (skip if a tap
    /// delivered within 2s), 1.2s debounce, and rebuild-storm cap all apply
    /// unchanged. NOTE: our own rebuild changes the rate (48 k→24 k) and WILL
    /// re-fire this listener; that echo is absorbed by the ground-truth gate (the
    /// tap is now delivering) plus the debounce — no extra suppression needed here.
    private func installHALListener(for deviceID: AudioDeviceID) {
        removeHALListener()
        let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            let selector = count > 0 ? addresses.pointee.mSelector : nil
            diagLog("[MIC-HAL] device \(deviceID) property change (selector \(selector.map { String(fourCC: $0) } ?? "?")) — synthesizing config-change")
            // Read the callback live (like the engine-config observer) so it
            // tracks any reassignment; invoke the SAME debounced rebuild path.
            self?.onConfigurationChange?()
        }
        for var address in Self.halWatchedAddresses {
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
            if status != noErr {
                diagLog("[MIC-HAL] add listener (selector \(String(fourCC: address.mSelector))) failed: OSStatus \(status)")
            }
        }
        _halListener = (block: block, deviceID: deviceID)
    }

    private func installConfigObserver(for engine: AVAudioEngine) {
        removeConfigObserver()
        let callback = { [weak self] in self?.onConfigurationChange?() }
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            // UNCONDITIONAL, first line, before any debounce/gating downstream:
            // future logs must settle whether macOS actually posts this in the
            // AirPods cold-start scenario (the diagnosed bug: it appears never to
            // fire, or fires before this observer is attached — installed AFTER
            // engine.start() below). If [MIC-CONFIG] is absent from a silent
            // cold-start log, the HAL fast path is the only notification we get.
            diagLog("[MIC-CONFIG] AVAudioEngineConfigurationChange received")
            diagLog("[MIC-CONFIG] engine stopped by a route/graph change")
            callback()
        }
        _configObserver.withLock { $0 = token }
    }

    /// - Parameter recordOutputURL: when non-nil, the mic track is also written to a
    ///   WAV at this path (float32 mono) for post-session retention. Multi-channel
    ///   devices are downmixed to mono (all channels averaged) so the live mic
    ///   survives regardless of which channel it lands on.
    /// - Parameter adoptExistingRecording: when true, a valid WAV already at
    ///   `recordOutputURL` is reopened in `.append` mode at its on-disk header
    ///   rate instead of being rotated aside — the caller vouches that the file
    ///   is THIS session's earlier audio (a pre-restart capture by this
    ///   instance, or the SCK leg's when a rebuild moves the system leg onto a
    ///   device). Engine-directed, never inferred from file existence: session
    ///   ids are second-resolution timestamps, so a colliding NEW session must
    ///   rotate the old file aside (the `.create` path), not append to it.
    ///
    /// The bring-up runs on the HAL queue with a deadline (2026-07-25 hang
    /// fix): a driver that wedges `engine.start()` costs the caller a
    /// `.timedOut` after ~5s instead of freezing its actor forever. A
    /// timed-out bind is torn down and its engine parked the moment the driver
    /// releases it (`teardownAbandonedBind`); until then every further HAL
    /// call fails fast with `.halWedged`.
    func bufferStream(
        deviceID: AudioDeviceID? = nil,
        recordOutputURL: URL? = nil,
        adoptExistingRecording: Bool = false
    ) async -> Result<AsyncStream<AVAudioPCMBuffer>, CaptureBindError> {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let outcome = await HALQueue.run(
            label: "capture-bind",
            work: { self.performBind(continuation: continuation, deviceID: deviceID, recordOutputURL: recordOutputURL, adoptExistingRecording: adoptExistingRecording) },
            onAbandoned: { setupError in
                self.teardownAbandonedBind(continuation: continuation, setupError: setupError)
            }
        )
        switch outcome {
        case .completed(nil):
            return .success(stream)
        case .completed(let message?):
            return .failure(.setupFailed(message))
        case .timedOut:
            return .failure(.timedOut)
        case .wedged:
            return .failure(.halWedged)
        }
    }

    /// The entire HAL bring-up. HAL-queue only. Returns nil on success, or the
    /// failure message (which is also in `captureError`, with the continuation
    /// already finished — the pre-async contract, unchanged).
    private func performBind(
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        deviceID: AudioDeviceID?,
        recordOutputURL: URL?,
        adoptExistingRecording: Bool
    ) -> String? {
        let level = _audioLevel
        let errorHolder = _error
        errorHolder.value = nil
            // Each (re)bind proves itself anew: a mid-session swap onto an unfed
            // virtual device must not inherit the previous device's non-zero flag.
            self._sawNonzeroSample.withLock { $0 = false }
            // Same per-bind semantics for the content counters (matches
            // SystemAudioCapture, which resets both in its own bufferStream).
            self._content.reset()

            // Track the live continuation so `stop()` can finish the stream.
            // Any predecessor was already finished by the `stop()` that precedes
            // every re-entry here (finish is defensive — a second finish on an
            // already-finished continuation is a no-op).
            self._streamContinuation.withLock { existing in
                existing?.finish()
                existing = continuation
            }

            diagLog("[MIC-1] bufferStream called, deviceID=\(String(describing: deviceID))")

            // Detach the config-change observer BEFORE touching the old engine:
            // teardown can itself fire AVAudioEngineConfigurationChange on that
            // engine, and an observer still attached would schedule a rebuild of
            // the capture we are deliberately replacing — a self-sustaining
            // restart loop that hammers the HAL (which then starts refusing
            // device binds with 'nope').
            self.removeConfigObserver()
            // Same idempotency for the HAL fast-path listener: bufferStream is
            // re-entered on every rebuild, so drop any prior device's listener
            // before we (re)register below.
            self.removeHALListener()

            // Fresh engine per capture — see the `engine` property comment. Tear the
            // old one down first so its HAL unit releases the previous device.
            // Teardown of a wedged engine (mid Bluetooth-graph transition) can raise
            // an NSException just like tap installation — guard it the same way.
            let teardownException = TomeCatchObjCException {
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
            }
            if let teardownException {
                diagLog("[MIC-1-WARN] old engine teardown raised \(teardownException) — abandoning old engine instance")
            }
            // Do NOT let the old engine deallocate here. AVFAudio queues
            // IOUnitPropertyListener / IOBindingChanged blocks asynchronously on
            // its AVAudioIOUnit queue when a device changes (AirPods connecting),
            // and those blocks capture pointers into the engine that registered
            // them. Releasing the engine while blocks are still queued is a
            // use-after-free inside AVFAudio — field crash 2026-07-06 (macOS
            // 26.2): SIGSEGV in objc_msgSend(sampleRate) from
            // AVAudioIOUnit::IOUnitPropertyListener, PAC failure on a freed
            // pointer. Park the retiring engine long enough for any queued
            // callbacks to drain against a live (stopped, harmless) object.
            Self.retire(self.engine)
            self.engine = AVAudioEngine()

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
                    return msg
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
                let name = Self.deviceName(for: id) ?? "?"
                diagLog("[MIC-2] setInputDevice device \(id) \"\(name)\" status=\(status) (0=ok)")
                // Surface a real failure to the UI — historically the silent fallback
                // to "system default" hid disconnected-USB-mic cases entirely.
                guard status == noErr else {
                    let msg = "Failed to set mic device \(id): OSStatus \(status)"
                    diagLog("[MIC-2-FAIL] \(msg)")
                    errorHolder.value = msg
                    continuation.finish()
                    return msg
                }
            } else {
                let defID = Self.defaultInputDeviceID()
                let name = defID.flatMap { Self.deviceName(for: $0) } ?? "?"
                diagLog("[MIC-2] no deviceID, using system default device \(String(describing: defID)) \"\(name)\"")
            }

            let inputNode = self.engine.inputNode
            // Tap format must match the HARDWARE input format. outputFormat(forBus:)
            // can report a stale rate after the device's nominal sample rate changes
            // (observed 2026-07-03: node said 44.1kHz, hw was 48kHz — installTap threw
            // an NSException that later took down the whole process).
            let format = inputNode.inputFormat(forBus: 0)

            diagLog("[MIC-3] inputNode format: sr=\(format.sampleRate) ch=\(format.channelCount) interleaved=\(format.isInterleaved) commonFormat=\(format.commonFormat.rawValue)")

            guard format.sampleRate > 0 && format.channelCount > 0 else {
                let msg = "Invalid audio format: sr=\(format.sampleRate) ch=\(format.channelCount)"
                diagLog("[MIC-3-FAIL] \(msg)")
                errorHolder.value = msg
                continuation.finish()
                return msg
            }

            guard let tapFormat = Self.makeTapFormat(from: format) else {
                let msg = "Failed to build tap format from input format"
                diagLog("[MIC-4-FAIL] \(msg)")
                errorHolder.value = msg
                continuation.finish()
                return msg
            }

            diagLog("[MIC-4] tapFormat: sr=\(tapFormat.sampleRate) ch=\(tapFormat.channelCount)")

            // Any previously-open writer instance should already be closed by
            // `stop()` before a restart calls back into here; close defensively
            // in case that invariant ever changes, to avoid leaking a FileHandle.
            self._retentionWriter.withLock { state in
                state?.writer.close()
                state = nil
            }

            // Open the retention WAV writer (mono float32) before the tap fires.
            // When the caller marked this bind as adopting an existing recording
            // (mid-session mic restart, device-leg rebuild, SCK→device adoption),
            // reopen the file in `.append` mode at its ON-DISK header rate and
            // keep going rather than rotating it aside — the audio already there
            // is this session's earlier capture, and diarization must see one
            // continuous file. The header rate (not the tap's, not any remembered
            // rate) is authoritative: the file may have been created by the SCK
            // writer at 48 kHz while this device's native rate differs.
            var newRetention: RetentionWriter?
            var isFreshRecording = true

            if let url = recordOutputURL {
                if adoptExistingRecording, let onDiskRate = WAVStreamWriter.headerSampleRate(at: url) {
                    do {
                        let writer = try WAVStreamWriter(
                            url: url,
                            sampleRate: onDiskRate,
                            channels: 1,
                            mode: .append
                        )
                        // Buffers reach the writer already downmixed to mono (see the
                        // tap callback), so the resampler is built mono→mono — NOT at
                        // tapFormat.channelCount, which for a multi-channel device
                        // (AirPods HFP, aggregates) would mismatch the actual buffers.
                        var converter: AVAudioConverter?
                        if tapFormat.sampleRate != onDiskRate,
                           let tapMono = AVAudioFormat(
                               standardFormatWithSampleRate: tapFormat.sampleRate,
                               channels: 1
                           ),
                           let writerFormat = AVAudioFormat(
                               standardFormatWithSampleRate: onDiskRate,
                               channels: 1
                           ) {
                            converter = AVAudioConverter(from: tapMono, to: writerFormat)
                        }
                        newRetention = RetentionWriter(writer: writer, converter: converter)
                        isFreshRecording = false
                    } catch {
                        diagLog("[MIC-WAV-FAIL] could not reopen writer at \(url.path) for append: \(error) — starting a fresh recording")
                    }
                }

                if newRetention == nil {
                    do {
                        let writer = try WAVStreamWriter(url: url, sampleRate: tapFormat.sampleRate, channels: 1, mode: .create)
                        newRetention = RetentionWriter(writer: writer, converter: nil)
                    } catch {
                        diagLog("[MIC-WAV-FAIL] could not open writer at \(url.path): \(error)")
                    }
                }
            }

            let finalRetention = newRetention
            self._retentionWriter.withLock { $0 = finalRetention }
            // Only a genuinely fresh file resets the session-start anchor the
            // post-session mixer aligns this track against — an appended
            // continuation must keep the original timestamp or the preserved
            // audio would be scheduled starting at the restart moment instead
            // of the true session start.
            if isFreshRecording {
                self._firstSampleTime.withLock { $0 = nil }
            }

            let retentionWriter = self._retentionWriter
            let firstSampleTime = self._firstSampleTime
            let lastSampleTime = self._lastSampleTime
            let sawNonzeroSample = self._sawNonzeroSample
            let content = self._content

            var tapCallCount = 0
            let installException = TomeCatchObjCException {
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
                tapCallCount += 1
                let rms = Self.normalizedRMS(from: buffer)
                level.value = min(rms * 25, 1.0)
                if rms > 0 { sawNonzeroSample.withLock { $0 = true } }
                content.noteBuffer(rms: rms)

                if tapCallCount <= 5 || tapCallCount % 100 == 0 {
                    diagLog("[MIC-6] tap #\(tapCallCount): frames=\(buffer.frameLength) rms=\(rms) level=\(level.value)")
                }

                firstSampleTime.withLock { if $0 == nil { $0 = Date() } }
                lastSampleTime.withLock { $0 = Date() }

                // Normalize to mono before writing/yielding: the WAV writer and the
                // transcriber's fallback path both read channel 0 only, so a
                // multi-channel device (aggregate, AirPods HFP) whose live mic sits
                // on a later channel would otherwise record pure silence.
                guard let mono = Self.downmixToMono(buffer) else { return }
                retentionWriter.withLock { state in
                    guard let state else { return }
                    let payload: AVAudioPCMBuffer
                    if let converter = state.converter {
                        guard let resampled = Self.resample(mono, using: converter) else { return }
                        payload = resampled
                    } else {
                        payload = mono
                    }
                    do {
                        try state.writer.write(payload)
                    } catch {
                        // Previously `try?`-swallowed. Counted (and throttle-logged
                        // like the SCK writer) so a device-backed system leg seeds
                        // SessionHandle.wavWriteErrorCount with real data.
                        let total = content.noteWriteError()
                        if total == 1 || total % 100 == 0 {
                            diagLog("[MIC-WAV-FAIL] write #\(total) failed: \(error)")
                        }
                    }
                }

                continuation.yield(mono)
                }
            }
            if let installException {
                // The device format can still change between the query above and the
                // install (raising a "Format mismatch" NSException). Fail the capture
                // cleanly — letting the exception escape corrupts the process.
                let msg = "Mic tap failed: \(installException)"
                diagLog("[MIC-5-FAIL] \(msg)")
                errorHolder.value = msg
                self._retentionWriter.withLock { state in
                    state?.writer.close()
                    state = nil
                }
                continuation.finish()
                return msg
            }

            diagLog("[MIC-5] tap installed, preparing engine...")

            // HAL fast path: register the device-property listener BEFORE
            // engine.start() so the A2DP→HFP rate flip is caught the moment it
            // happens — including if it lands DURING or immediately after start,
            // the exact race the engine notification misses. Resolve the device
            // the same way the audio unit did: an explicit deviceID, else the
            // system default.
            let resolvedDeviceID = deviceID ?? Self.defaultInputDeviceID()
            if let resolvedDeviceID {
                self.installHALListener(for: resolvedDeviceID)
            } else {
                diagLog("[MIC-HAL] no resolvable device — skipping HAL fast-path listener")
            }

            var startError: Error?
            let startException = TomeCatchObjCException {
                do {
                    self.engine.prepare()
                    diagLog("[MIC-7] engine prepared, starting...")
                    try self.engine.start()
                    diagLog("[MIC-8] engine started successfully, isRunning=\(self.engine.isRunning)")
                    // Seed the watchdog baseline — grace period starts at engine
                    // start, not at the first buffer (which a wedged device never
                    // sends). Deliberately NOT _lastSampleTime: only real tap
                    // buffers may clear a stall.
                    self._captureStartTime.withLock { $0 = Date() }
                    // Route/graph changes stop this engine silently; watch for them.
                    self.installConfigObserver(for: self.engine)
                } catch {
                    startError = error
                }
            }
            if startException != nil || startError != nil {
                let msg = "Mic failed: \(startException ?? startError!.localizedDescription)"
                diagLog("[MIC-8-FAIL] \(msg)")
                errorHolder.value = msg
                self.removeHALListener()
                inputNode.removeTap(onBus: 0)
                self._retentionWriter.withLock { state in
                    state?.writer.close()
                    state = nil
                }
                continuation.finish()
                return msg
            }
            return nil
    }

    /// Runs on the HAL queue when the driver finally releases a bind whose
    /// caller stopped waiting. Whatever the bind built must not keep capturing
    /// into a stream nobody consumes — tear it down NOW (safe: the wedged call
    /// has returned and this block is serialized behind it), then park the
    /// engine for the process lifetime. By the time this runs, `HALQueue` has
    /// already cleared the wedge latch, and any queued bind runs after us on a
    /// fresh engine.
    private func teardownAbandonedBind(
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        setupError: String?
    ) {
        diagLog("[MIC-ABANDON] timed-out bind released by the driver (setup error: \(setupError ?? "none")) — tearing down the abandoned capture")
        removeConfigObserver()
        removeHALListener()
        let teardownException = TomeCatchObjCException {
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
        }
        if let teardownException {
            diagLog("[MIC-ABANDON-WARN] teardown raised \(teardownException)")
        }
        Self.retireForever(self.engine)
        self.engine = AVAudioEngine()
        continuation.finish()
        _retentionWriter.withLock { state in
            state?.writer.close()
            state = nil
        }
        _audioLevel.value = 0
    }

    func stop() async {
        // Engine/HAL teardown belongs to the HAL queue: `engine.stop()` on a
        // wedged device blocks exactly like `engine.start()` does, and it used
        // to run on the main actor (9 call sites).
        let outcome = await HALQueue.run(
            label: "capture-stop",
            work: {
                self.removeConfigObserver()
                self.removeHALListener()
                let teardownException = TomeCatchObjCException {
                    self.engine.inputNode.removeTap(onBus: 0)
                    self.engine.stop()
                }
                if let teardownException {
                    diagLog("[MIC-STOP-WARN] engine teardown raised \(teardownException)")
                }
            },
            onAbandoned: { _ in
                // The wedged teardown finally finished — the engine object is
                // stopped, but nothing waited for it. Park it and give the
                // instance a fresh engine for the next bind.
                Self.retireForever(self.engine)
                self.engine = AVAudioEngine()
            }
        )
        switch outcome {
        case .timedOut:
            diagLog("[MIC-STOP] teardown wedged past the deadline — stream finish and writer close proceed anyway")
        case .wedged:
            // An earlier bind/stop is still stuck; the engine can't be touched.
            // Its abandonment handler owns the eventual teardown.
            diagLog("[MIC-STOP] HAL wedged — skipping engine teardown; abandoned-op handler owns it")
        case .completed:
            break
        }
        // The tap is gone (or its yields land in a finished stream) — finish
        // the stream so the consumer drains what's buffered and runs its
        // end-of-stream flush. The engine's stop path awaits that drain;
        // without the finish it would have to cancel, which drops the tail
        // utterance. Lock-protected state is safe from any thread — run it
        // even when the HAL teardown is stuck so the WAV finalizes.
        _streamContinuation.withLock { $0?.finish(); $0 = nil }
        _audioLevel.value = 0
        _lastSampleTime.withLock { $0 = nil }
        _captureStartTime.withLock { $0 = nil }
        // Flush + finalize the retention WAV. firstSampleTime is intentionally
        // preserved so the engine can snapshot it after stop.
        _retentionWriter.withLock { state in
            state?.writer.close()
            state = nil
        }
    }

    /// Resample `buffer` to `converter`'s output format (established when the
    /// retention writer was first opened), for a mid-session mic restart whose
    /// newly-attached device runs at a different native sample rate.
    /// Tap format for an input node. The "standard" initializer only covers mono and
    /// stereo — it returns nil for >2 channels, which is exactly what AirPods-HFP and
    /// aggregate devices report (e.g. 24 kHz / 3 ch); that nil made those devices
    /// unrecordable (MIC-4-FAIL before the tap was ever installed). Fall back to the
    /// node's own format — always installable on its own node — and let
    /// `downmixToMono` normalize the buffers afterward.
    static func makeTapFormat(from format: AVAudioFormat) -> AVAudioFormat? {
        if let standard = AVAudioFormat(
            standardFormatWithSampleRate: format.sampleRate,
            channels: format.channelCount
        ) {
            return standard
        }
        return format
    }

    /// Average all channels into a mono float32 non-interleaved buffer at the same
    /// sample rate. Downstream consumers (WAV writer, transcriber fallback) read
    /// channel 0 only, so an aggregate whose live mic lands on a later channel would
    /// record pure silence without this. Mono float32 input passes through untouched.
    /// Returns nil for empty buffers or unsupported sample layouts.
    static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }

        let fmt = buffer.format
        if fmt.channelCount == 1 && fmt.commonFormat == .pcmFormatFloat32 && !fmt.isInterleaved {
            return buffer
        }

        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        mono.frameLength = AVAudioFrameCount(frames)
        let out = mono.floatChannelData![0]
        let channelCount = Int(max(fmt.channelCount, 1))
        let scale = 1 / Float(channelCount)

        func fill(_ sampleAt: (_ frame: Int, _ channel: Int) -> Float) {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += sampleAt(frame, channel)
                }
                out[frame] = sum * scale
            }
        }

        if let channelData = buffer.floatChannelData {
            fill { frame, channel in
                fmt.isInterleaved
                    ? channelData[0][(frame * channelCount) + channel]
                    : channelData[channel][frame]
            }
        } else if let channelData = buffer.int16ChannelData {
            let s: Float = 1 / Float(Int16.max)
            fill { frame, channel in
                (fmt.isInterleaved
                    ? Float(channelData[0][(frame * channelCount) + channel])
                    : Float(channelData[channel][frame])) * s
            }
        } else if let channelData = buffer.int32ChannelData {
            let s: Float = 1 / Float(Int32.max)
            fill { frame, channel in
                (fmt.isInterleaved
                    ? Float(channelData[0][(frame * channelCount) + channel])
                    : Float(channelData[channel][frame])) * s
            }
        } else {
            return nil
        }

        return mono
    }

    private static func resample(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let targetFormat = converter.outputFormat
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrames = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 8
        guard outputFrames > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames)
        else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            diagLog("[MIC-WAV-RESAMPLE-FAIL] \(error.localizedDescription)")
            return nil
        }
        return outputBuffer
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

    // MARK: - Off-main device enumeration (HAL-queue hopped)

    // Async overloads of the enumeration statics below. Every
    // `AudioObjectGetPropertyData` can block on a wedged driver, so an actor
    // context must never call the sync versions directly — these hop onto the
    // HAL queue with the standard deadline and degrade to nil/[] instead of
    // freezing the caller. Swift's overload resolution picks these
    // automatically in async contexts (and requires the `await`); the sync
    // versions remain for the HAL queue itself (`performBind`) and tests.

    static func availableInputDevices() async -> [(id: AudioDeviceID, uid: String, name: String)] {
        await availableInputDevicesResult().value(or: [])
    }

    /// Enumeration that distinguishes "the machine has no input devices" from
    /// "the HAL never answered" — the Settings pickers must keep their current
    /// list in the second case rather than render every selection unavailable.
    static func availableInputDevicesResult() async -> HALQueryResult<[(id: AudioDeviceID, uid: String, name: String)]> {
        await HALQueue.query(label: "enumerate-input-devices") { availableInputDevices() }
    }

    static func deviceName(for deviceID: AudioDeviceID) async -> String? {
        await HALQueue.query(label: "device-name") { deviceName(for: deviceID) }.value(or: nil)
    }

    static func deviceID(forUID uid: String) async -> AudioDeviceID? {
        await deviceIDResult(forUID: uid).value(or: nil)
    }

    /// UID resolution that keeps "no such device present" (`.answered(nil)`)
    /// separate from "the HAL is unresponsive" (`.unavailable`). Every caller
    /// that reacts to an absent device by binding something ELSE must use this:
    /// during a wedge the substitute is typically the wedged device itself.
    static func deviceIDResult(forUID uid: String) async -> HALQueryResult<AudioDeviceID?> {
        await HALQueue.query(label: "device-for-uid") { deviceID(forUID: uid) }
    }

    static func deviceUID(for deviceID: AudioDeviceID) async -> String? {
        await HALQueue.query(label: "device-uid") { deviceUID(for: deviceID) }.value(or: nil)
    }

    static func defaultInputDeviceID() async -> AudioDeviceID? {
        await defaultInputDeviceIDResult().value(or: nil)
    }

    /// See `deviceIDResult(forUID:)` — same distinction for the system default.
    static func defaultInputDeviceIDResult() async -> HALQueryResult<AudioDeviceID?> {
        await HALQueue.query(label: "default-input-device") { defaultInputDeviceID() }
    }

    // MARK: - List available input devices

    static func availableInputDevices() -> [(id: AudioDeviceID, uid: String, name: String)] {
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

        var result: [(id: AudioDeviceID, uid: String, name: String)] = []

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

            result.append((id: deviceID, uid: deviceUID(for: deviceID) ?? "", name: name as String))
        }

        return result
    }

    /// Human-readable name for a resolved capture device, via CoreAudio's
    /// `kAudioObjectPropertyName` (CFString). Used only for diagnostics — it lets
    /// a silent cold-start log say `device 157 "Nic's AirPods Pro"` so the failing
    /// device is identifiable after the fact. Mirrors `deviceUID`'s call style.
    static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        return status == noErr ? name as String : nil
    }

    /// Resolve a persisted device UID to its current AudioDeviceID, or nil when
    /// no present input device carries that UID. Called at every capture bind —
    /// UIDs are stable across driver reloads/reboots while numeric IDs are not.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return availableInputDevices().first(where: { $0.uid == uid })?.id
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

private extension String {
    /// Render a CoreAudio four-char-code selector as its ASCII mnemonic (e.g.
    /// `nsrt`, `slay`) for diagnostic logs; falls back to the raw number.
    init(fourCC: FourCharCode) {
        let bytes = [
            UInt8((fourCC >> 24) & 0xFF),
            UInt8((fourCC >> 16) & 0xFF),
            UInt8((fourCC >> 8) & 0xFF),
            UInt8(fourCC & 0xFF),
        ]
        if bytes.allSatisfy({ (0x20...0x7E).contains($0) }) {
            self = String(bytes: bytes, encoding: .ascii) ?? "\(fourCC)"
        } else {
            self = "\(fourCC)"
        }
    }
}

/// Per-capture content telemetry: how many delivered buffers carried audible
/// content, and how many retention-WAV writes failed. Split out of `MicCapture`
/// so the accounting rules are unit-testable without an audio device — the tap
/// callback captures the instance the same way it captures the other locks.
///
/// The audible threshold is `SystemAudioCapture.audibleRMSThreshold` verbatim:
/// both legs must agree on what "audible" means, or the same meeting would be
/// judged silent on one capture path and not the other.
final class CaptureContentCounters: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<(audible: Int, writeErrors: Int)>(uncheckedState: (0, 0))

    var audibleBufferCount: Int { state.withLock { $0.audible } }
    var writeErrorCount: Int { state.withLock { $0.writeErrors } }

    /// Count one delivered buffer. Sub-threshold buffers are delivered-but-empty
    /// and deliberately don't count — that distinction is the whole point of the
    /// counter (a stream can deliver continuously while carrying pure silence).
    func noteBuffer(rms: Float) {
        guard rms > SystemAudioCapture.audibleRMSThreshold else { return }
        state.withLock { $0.audible += 1 }
    }

    /// Count one failed retention-WAV write; returns the new total so the caller
    /// can throttle its logging.
    @discardableResult
    func noteWriteError() -> Int {
        state.withLock { state -> Int in
            state.writeErrors += 1
            return state.writeErrors
        }
    }

    /// Reset both counters. Called on every `bufferStream` entry so a mid-session
    /// device rebuild starts its own accounting rather than inheriting the
    /// previous device's.
    func reset() {
        state.withLock { $0 = (0, 0) }
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
