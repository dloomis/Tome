@preconcurrency import AVFoundation
@preconcurrency import FluidAudio
import Foundation
import Observation
import os

// MARK: - Offline pass seam

/// One import's offline "live pass": transcribe an audio file exactly as the
/// live path transcribes a mic tap, delivering finalized utterances in order.
///
/// A protocol (rather than a concrete call into `StreamingTranscriber`) for the
/// same reason `VADStream` is one: it lets the coordinator's state machine —
/// validation, artifact creation, the §8 rollback rule, hand-off, gating — be
/// tested hermetically, with no ASR/VAD models and no audio.
protocol ImportLivePass: Sendable {
    /// - Parameters:
    ///   - fileURL: the file to read. Always Tome's own copy in the sessions
    ///     directory (§5.5), never the user's original.
    ///   - baseTime: wall-clock the recording started; anchors every utterance
    ///     timestamp so per-line offsets describe audio position, not replay time.
    ///   - isCancelled: polled between chunks. When it flips true the pass stops
    ///     feeding audio and drains — it must NOT cancel the transcriber's task
    ///     (a cancelled ASR flush silently drops the tail; see `StreamingTranscriber.run`).
    ///   - onProgress: `(framesConsumed, totalFrames)`, once per chunk.
    ///   - onUtterance: awaited, so when `run` returns every utterance has been
    ///     delivered — the caller closes the transcript immediately afterwards.
    func run(
        fileURL: URL,
        baseTime: Date,
        isCancelled: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onUtterance: @escaping @Sendable (String, Date) async -> Void
    ) async -> ImportPassOutcome
}

/// Production pass: `FileAudioReader` → `StreamingTranscriber` (speaker `.you`,
/// a fresh Silero VAD, the app's shared `ASRCoordinator`).
///
/// The reader's stream is handed to the transcriber essentially unmodified — one
/// thin gate wraps it so a cancel can end it at a chunk boundary. That gate is
/// deliberately another *pull-based* stream: bouncing the buffers through a
/// yielding continuation would reintroduce exactly the unbounded buffering
/// `FileAudioReader` exists to avoid.
final class StreamingImportPass: ImportLivePass {
    private let asr: ASRCoordinator
    private let makeVAD: @Sendable () async throws -> any VADStream

    init(
        asr: ASRCoordinator,
        makeVAD: @escaping @Sendable () async throws -> any VADStream = {
            SileroVADStream(manager: try await VadManager())
        }
    ) {
        self.asr = asr
        self.makeVAD = makeVAD
    }

    /// Single-consumer adapter over the reader's iterator. `@unchecked Sendable`
    /// on the same terms as `StreamingTranscriber`: exactly one task pulls it.
    private final class BufferPump: @unchecked Sendable {
        private var iterator: AsyncStream<AVAudioPCMBuffer>.AsyncIterator
        init(_ stream: AsyncStream<AVAudioPCMBuffer>) {
            iterator = stream.makeAsyncIterator()
        }
        func next() async -> AVAudioPCMBuffer? { await iterator.next() }
    }

    func run(
        fileURL: URL,
        baseTime: Date,
        isCancelled: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onUtterance: @escaping @Sendable (String, Date) async -> Void
    ) async -> ImportPassOutcome {
        let reader: FileAudioReader
        do {
            reader = try FileAudioReader(url: fileURL)
        } catch {
            return .readFailed(error.localizedDescription)
        }

        let vad: any VADStream
        do {
            vad = try await makeVAD()
        } catch {
            diagLogError("[IMPORT] VAD unavailable for \(fileURL.lastPathComponent): \(error)")
            return .engineFailed("Speech detection isn't available — check Settings ▸ Transcription")
        }

        let transcriber = StreamingTranscriber(
            asrCoordinator: asr,
            vad: vad,
            speaker: .you,
            audioSource: .microphone,
            baseTime: baseTime,
            onPartial: { _ in },        // no live UI for imports (§6.1)
            onFinal: onUtterance
        )

        let pump = BufferPump(reader.buffers(onProgress: { progress in
            onProgress(progress.framesConsumed, progress.totalFrames)
        }))
        let gated = AsyncStream<AVAudioPCMBuffer>(unfolding: {
            isCancelled() ? nil : await pump.next()
        })

        _ = await transcriber.run(stream: gated)

        if isCancelled() { return .cancelled }
        if let readError = reader.readError { return .readFailed(readError) }
        return .completed
    }
}

// MARK: - Coordinator configuration

/// Post-processing settings applied to the `PostProcessingJob` an import hands
/// off — the same values `ContentView.stopSession` reads for a native session.
struct ImportPostProcessingOptions: Sendable {
    var clusterThreshold: Float = 0.7
    var numberOfSpeakers: Int = 0
    var mergeGapSeconds: Double = 1.5
    var retention: RecordingRetentionConfig?
    var exportVoiceprints: Bool = false

    init(
        clusterThreshold: Float = 0.7,
        numberOfSpeakers: Int = 0,
        mergeGapSeconds: Double = 1.5,
        retention: RecordingRetentionConfig? = nil,
        exportVoiceprints: Bool = false
    ) {
        self.clusterThreshold = clusterThreshold
        self.numberOfSpeakers = numberOfSpeakers
        self.mergeGapSeconds = mergeGapSeconds
        self.retention = retention
        self.exportVoiceprints = exportVoiceprints
    }
}

/// Everything the import stage needs from settings and storage locations,
/// snapshotted once per job at the moment it starts (so a settings change
/// mid-queue applies to the next file, never to one in flight).
struct ImportEnvironment: Sendable {
    /// Where the WAV copy, sidecar and JSONL live — the same directory native
    /// captures use, so the launch-time orphan scan finds an interrupted import.
    /// Nil when it can't be resolved (Application Support unwritable): the job
    /// then *refuses* rather than writing artifacts somewhere the orphan scan
    /// and crash recovery never look.
    var sessionsDirectory: URL?
    /// Voice-memo output folder (`AppSettings.vaultVoicePath`).
    var vaultPath: String
    var filenameDateFormat: String
    /// `AppSettings.filenameVoiceLabel`.
    var filenameTypeLabel: String?
    /// Directories a source file may not come from (§5.4).
    var protectedDirectories: [URL]
    var postProcessing: ImportPostProcessingOptions

    init(
        sessionsDirectory: URL?,
        vaultPath: String,
        filenameDateFormat: String = "yyyy-MM-dd HH-mm-ss",
        filenameTypeLabel: String? = nil,
        protectedDirectories: [URL] = [],
        postProcessing: ImportPostProcessingOptions = ImportPostProcessingOptions()
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.vaultPath = vaultPath
        self.filenameDateFormat = filenameDateFormat
        self.filenameTypeLabel = filenameTypeLabel
        self.protectedDirectories = protectedDirectories
        self.postProcessing = postProcessing
    }
}

/// Terminal record of one file's import, accumulated for the (v2) batch summary
/// and for the status row's "what just happened" text.
struct ImportResult: Identifiable, Sendable {
    enum Outcome: Equatable, Sendable {
        case imported(transcriptURL: URL)
        case failed(String)
        case cancelled
    }

    let id: String
    let sourceURL: URL
    let outcome: Outcome
    let finishedAt: Date

    var isSuccess: Bool {
        if case .imported = outcome { return true }
        return false
    }

    /// User-facing text, or nil when there's nothing to say (success/cancel).
    var message: String? {
        if case .failed(let text) = outcome { return text }
        return nil
    }
}

// MARK: - Coordinator

/// Serial consumer for imports (§6.1). Owns the FIFO, runs one file at a time,
/// and hands each finished import to the ordinary `PostProcessingQueue`.
///
/// **Gating (§7).** A job starts only while the app is idle — no live session and
/// no session in the pending window (`AppServices.isSessionPending`, which covers
/// press → engine-live and stop → job-enqueued). Two properties make that sound:
///
/// - The idle probe and the commit (`activeJob = job`) happen in one synchronous
///   main-actor block with no `await` between them, so a session start can never
///   interleave into the gap and find both "no import running" and "no session
///   pending" true at once.
/// - The probe is consulted only at *start*. A recording that begins while an
///   import is already running does **not** cancel it: the two workloads share
///   the `ASRCoordinator`, which serializes their decodes exactly as background
///   re-transcription already serializes against live streaming. Only the *next*
///   queued file waits.
@Observable
@MainActor
final class ImportCoordinator {

    /// Frontmatter provenance for imported notes (§11.1) — the note type stays
    /// voice-memo, but downstream tooling can tell where the audio came from.
    static let importedSourceApp = "Imported"

    private(set) var pendingJobs: [ImportJob] = []
    private(set) var activeJob: ImportJob?
    /// One entry per finished file, in completion order (v2 batch summary, §9).
    private(set) var results: [ImportResult] = []

    var lastResult: ImportResult? { results.last }
    /// Drives `AppServices.isImporting` — true while a file is validating,
    /// preparing or transcribing.
    var isImporting: Bool { activeJob != nil }
    /// Files enqueued but blocked on a live session ("Waiting for the current
    /// recording to finish…").
    var isWaitingForIdle: Bool { activeJob == nil && !pendingJobs.isEmpty }
    var inFlightCount: Int { pendingJobs.count + (activeJob == nil ? 0 : 1) }

    private let pass: any ImportLivePass
    private let environment: @MainActor () -> ImportEnvironment
    private let isIdle: @MainActor () -> Bool
    private let enqueuePostProcessing: @MainActor (PostProcessingJob) -> Void
    private let now: @Sendable () -> Date
    private let idleRetryInterval: Duration

    private var runTask: Task<Void, Never>?
    private var idleRetryTask: Task<Void, Never>?

    /// - Parameters:
    ///   - isIdle: at minimum `activeSessionType == nil && !services.isSessionPending`
    ///     (§7); the app may fold in further readiness — e.g.
    ///     `modelProvisioner.canStartRecording` — since a queued import that
    ///     waits for the model is better than one that fails on it. Called on
    ///     the main actor immediately before each job starts.
    ///   - enqueuePostProcessing: the app's `services.postProcessingQueue.enqueue`.
    ///   - idleRetryInterval: backstop poll for the case where nothing calls
    ///     `sessionStateDidChange()` after a recording ends. Pokes are the
    ///     primary mechanism; this only bounds the damage of a missing one.
    init(
        pass: any ImportLivePass,
        environment: @escaping @MainActor () -> ImportEnvironment,
        isIdle: @escaping @MainActor () -> Bool,
        enqueuePostProcessing: @escaping @MainActor (PostProcessingJob) -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        idleRetryInterval: Duration = .seconds(1)
    ) {
        self.pass = pass
        self.environment = environment
        self.isIdle = isIdle
        self.enqueuePostProcessing = enqueuePostProcessing
        self.now = now
        self.idleRetryInterval = idleRetryInterval
    }

    // MARK: - Intake

    /// Queue files for import. List-shaped from day one (§9); v1 callers pass a
    /// single element. Only the cheap type gate runs here — the decode, duration
    /// and self-import gates run when the job starts, against the state of the
    /// world at that moment.
    func enqueue(_ urls: [URL]) {
        for url in urls {
            let job = ImportJob(sourceURL: url)
            do {
                try ImportSupport.validateType(url)
            } catch let error as ImportError {
                diagLog("[IMPORT] rejected \(job.displayName) at intake: \(error.errorDescription ?? "")")
                job.enter(.failed(error))
                record(job, .failed(error.errorDescription ?? "Couldn't import \(job.displayName)"))
                continue
            } catch {
                job.enter(.failedInternal(error.localizedDescription))
                record(job, .failed(error.localizedDescription))
                continue
            }
            pendingJobs.append(job)
        }
        startNextIfPossible()
    }

    /// Poke from the app when a live session starts/ends (or the pending window
    /// closes). Cheap and idempotent.
    func sessionStateDidChange() {
        startNextIfPossible()
    }

    /// Cancel a specific job. A queued job is dropped immediately; the running
    /// one is asked to stop and then goes through the ordinary §8 rule — which
    /// keeps a partial transcript rather than destroying it.
    func cancel(_ job: ImportJob) {
        job.cancel()
        if let index = pendingJobs.firstIndex(where: { $0 === job }) {
            pendingJobs.remove(at: index)
            job.enter(.cancelled)
            record(job, .cancelled)
            startNextIfPossible()
        }
    }

    func cancelActiveJob() {
        if let activeJob { cancel(activeJob) }
    }

    /// Cancel everything — the running file and the rest of the queue. The queue
    /// is emptied *before* any per-job bookkeeping runs: routing through
    /// `cancel(_:)` would call `startNextIfPossible` between removals, which can
    /// promote a later queued job to active moments before its own cancel lands —
    /// the user watches an import they just cancelled start up.
    func cancelAll() {
        activeJob?.cancel()
        let queued = pendingJobs
        pendingJobs.removeAll()
        for job in queued {
            job.cancel()
            job.enter(.cancelled)
            record(job, .cancelled)
        }
        startNextIfPossible()
    }

    // MARK: - Drain

    private func startNextIfPossible() {
        guard activeJob == nil else { return }
        guard !pendingJobs.isEmpty else { cancelIdleRetry(); return }
        // The check and the commit below must stay in one synchronous block: an
        // `await` here would open the window where a session start and this
        // start each see an idle app.
        guard isIdle() else {
            diagLog("[IMPORT] \(pendingJobs.count) file(s) waiting — a session is active or pending")
            scheduleIdleRetry()
            return
        }
        cancelIdleRetry()
        let job = pendingJobs.removeFirst()
        activeJob = job
        runTask = Task { [weak self] in
            await self?.run(job)
            guard let self else { return }
            self.activeJob = nil
            self.runTask = nil
            self.startNextIfPossible()
        }
    }

    private func scheduleIdleRetry() {
        guard idleRetryTask == nil else { return }
        idleRetryTask = Task { [idleRetryInterval] in
            try? await Task.sleep(for: idleRetryInterval)
            guard !Task.isCancelled else { return }
            self.idleRetryTask = nil
            self.startNextIfPossible()
        }
    }

    private func cancelIdleRetry() {
        idleRetryTask?.cancel()
        idleRetryTask = nil
    }

    // MARK: - One import

    private func run(_ job: ImportJob) async {
        let env = environment()
        let filename = job.displayName

        // ---- 1. Validate (§5 gates 2–4). Nothing has been created yet, so
        // every exit here is a plain report with no rollback to do.
        job.enter(.validating)
        guard !env.vaultPath.trimmingCharacters(in: .whitespaces).isEmpty else {
            // Without a destination the logger would create a note at a nonsense
            // path; refuse before anything is written.
            return fail(job, .failedInternal("Choose a voice-memo folder in Settings ▸ Output before importing"))
        }
        guard let sessionsDirectory = env.sessionsDirectory else {
            // Same refusal as the missing vault: without the real sessions
            // directory the crash-recovery artifacts would land somewhere the
            // orphan scan never looks, making an interrupted import unrecoverable.
            return fail(job, .failedInternal("Tome's sessions folder isn't available — check that Application Support is writable"))
        }
        let info: ImportSupport.AudioFileInfo
        let dates: (creation: Date?, modification: Date?)
        do {
            // Off the main actor: the decode gate opens the user's *original*
            // file, which often lives on removable/network media — a stalled
            // volume here must not beachball the app (the same hang class the
            // HALQueue work eliminated for capture binds).
            let sourceURL = job.sourceURL
            let protected = env.protectedDirectories
            (info, dates) = try await Task.detached {
                try ImportSupport.validateType(sourceURL)
                try ImportSupport.validateNotSelfImport(sourceURL, protectedDirectories: protected)
                let info = try ImportSupport.inspectAudioFile(at: sourceURL)
                try ImportSupport.validateDuration(info.duration, filename: sourceURL.lastPathComponent)
                return (info, ImportSupport.fileDates(at: sourceURL))
            }.value
        } catch let error as ImportError {
            return fail(job, .failed(error))
        } catch {
            return fail(job, .failedInternal(error.localizedDescription))
        }

        let stamps = ImportSupport.deriveTimestamps(
            creationDate: dates.creation,
            modificationDate: dates.modification,
            duration: info.duration,
            now: now()
        )
        job.setTimestamps(stamps)
        job.setTotalFrames(info.frameLength)
        diagLog("[IMPORT] \(filename): \(String(format: "%.1f", info.duration))s, \(info.sampleRate)Hz, \(info.channelCount)ch — dated from \(stamps.anchor.rawValue)")

        // ---- 2. Prepare: mint identity, copy the audio, open the dedicated
        // writers, stamp the crash-recovery sidecar. Every artifact is tracked
        // BEFORE it is written, so a failure halfway through a create still
        // leaves a complete rollback list.
        job.enter(.preparing)
        let sid = Self.uniqueSessionId(in: sessionsDirectory)
        let guid = UUID().uuidString.lowercased()
        job.setSession(id: sid, guid: guid)

        let micWav = sessionsDirectory.appendingPathComponent("\(sid).mic.wav")
        job.trackArtifact(micWav, as: .micWav)
        let source = job.sourceURL
        do {
            try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
            // Off the main actor: a long memo is hundreds of megabytes and this
            // is a synchronous copy.
            try await Task.detached {
                try FileManager.default.copyItem(at: source, to: micWav)
            }.value
        } catch {
            job.rollbackArtifacts()
            return fail(job, .failedInternal("Couldn't copy \(filename) into Tome's sessions folder: \(error.localizedDescription)"))
        }

        // Dedicated instances, never the app-lifetime ones (§6.3): those belong
        // to live recording, and an import claiming them would block a session
        // (or be corrupted by one).
        let store = SessionStore(directory: sessionsDirectory)
        job.trackArtifact(sessionsDirectory.appendingPathComponent("\(sid).jsonl"))
        await store.startSession(sessionId: sid)

        let logger = TranscriptLogger()
        let transcriptURL: URL
        do {
            transcriptURL = try await logger.startSession(
                sourceApp: Self.importedSourceApp,
                vaultPath: env.vaultPath,
                sessionType: .voiceMemo,
                sessionGuid: guid,
                calendarEventId: nil,
                suggestedFilename: nil,
                filenameDateFormat: env.filenameDateFormat,
                filenameTypeLabel: env.filenameTypeLabel,
                startedAt: stamps.start
            )
        } catch {
            await store.endSession()
            job.rollbackArtifacts()
            return fail(job, .failedInternal("Couldn't create the transcript: \(error.localizedDescription)"))
        }
        job.trackArtifact(transcriptURL, as: .transcript)
        // Names the finalized note after the source recording (§11.2).
        await logger.updateContext(job.sourceStem)

        SessionSidecar.emit(
            forWAV: micWav,
            context: SessionRecordingContext(
                sessionId: sid,
                sessionGuid: guid,
                transcriptURL: transcriptURL,
                sourceApp: Self.importedSourceApp,
                sessionType: .voiceMemo,
                startedAt: stamps.start
            ),
            sampleRate: info.sampleRate,
            channels: Int(info.channelCount)
        )
        job.trackArtifact(SessionSidecar.sidecarURL(forWAV: micWav))

        // ---- 3. Offline live pass over Tome's copy. A cancel requested during
        // prepare lands here and returns `.cancelled` on the first pull.
        job.enter(.transcribing)
        let channel = UtteranceWriteChannel(logger: logger, store: store)
        let committed = OSAllocatedUnfairLock(initialState: 0)
        // Mirrors the job's progress, but readable synchronously after the pass
        // returns — the main-actor hop below may still be in flight then, and a
        // partial pass derives its end time from this.
        let consumedFrames = OSAllocatedUnfairLock(initialState: Int64(0))
        let token = job.cancelToken
        let outcome = await pass.run(
            fileURL: micWav,
            baseTime: stamps.start,
            isCancelled: { token.isCancelled },
            onProgress: { [weak job] consumed, total in
                consumedFrames.withLock { $0 = max($0, consumed) }
                Task { @MainActor in job?.updateProgress(framesConsumed: consumed, totalFrames: total) }
            },
            onUtterance: { text, timestamp in
                committed.withLock { $0 += 1 }
                channel.write(speaker: .you, text: text, timestamp: timestamp)
            }
        )

        // Same barrier order as `ContentView.stopSession`: drain the writer
        // channel BEFORE the stores close, or the tail utterance is appended to
        // a file handle that's already gone.
        await channel.flush()
        channel.shutdown()
        await store.endSession()
        // A completed pass covered the whole file; any other ending stops at the
        // last consumed frame — stamping the full audio length there would claim
        // (say) 58 untranscribed minutes as covered in the note's `duration:`.
        let endTime: Date
        if outcome == .completed {
            endTime = stamps.end
        } else {
            let consumedSeconds = Double(consumedFrames.withLock { $0 }) / info.sampleRate
            endTime = min(stamps.end, stamps.start.addingTimeInterval(consumedSeconds))
        }
        let snapshot = await logger.endSession(endTime: endTime)

        guard let snapshot else {
            job.rollbackArtifacts()
            return fail(job, .failedInternal("Couldn't close the imported transcript"))
        }

        // Two independent signals that text landed. Take the larger: over-counting
        // keeps a recoverable transcript, under-counting deletes one (§8).
        let landed = max(committed.withLock { $0 }, snapshot.speakersDetected.isEmpty ? 0 : 1)
        job.setUtteranceCount(landed)

        // ---- 4. Disposition + hand-off.
        switch ImportJob.disposition(outcome: outcome, utteranceCount: landed, filename: filename) {
        case .unwind(let error):
            let removed = job.rollbackArtifacts()
            diagLog("[IMPORT] \(filename): rolled back \(removed.count) artifact(s) — outcome \(outcome), 0 utterances")
            switch (error, outcome) {
            case (.some(let error), _):
                fail(job, .failed(error))
            case (_, .engineFailed(let message)):
                fail(job, .failedInternal(message))
            default:
                job.enter(.cancelled)
                record(job, .cancelled)
            }

        case .handOff:
            if outcome != .completed {
                diagLogError("[IMPORT] \(filename): pass ended as \(outcome) with \(landed) utterance(s) — keeping the partial transcript and handing off")
            }
            let handle = SessionHandle(
                id: sid,
                sessionType: .voiceMemo,
                sourceApp: Self.importedSourceApp,
                wavBufferPath: nil,          // no system leg: imports are mic-only
                micWavPath: micWav,
                micFirstSampleTime: stamps.start,
                systemFirstSampleTime: nil,
                transcript: snapshot,
                origin: .imported
            )
            let options = env.postProcessing
            enqueuePostProcessing(PostProcessingJob(
                handle: handle,
                clusterThreshold: options.clusterThreshold,
                numberOfSpeakers: options.numberOfSpeakers,
                mergeGapSeconds: options.mergeGapSeconds,
                retention: options.retention,
                exportVoiceprints: options.exportVoiceprints,
                // Voice memos are never discarded for being short, however brief.
                discardIfShorterThanOrEqual: nil
            ))
            job.enter(.handedOff)
            record(job, .imported(transcriptURL: snapshot.filePath))
            diagLog("[IMPORT] \(filename) → \(snapshot.filePath.lastPathComponent) (\(landed) utterance(s)), handed to post-processing as \(sid)")
        }
    }

    // MARK: - Helpers

    private func fail(_ job: ImportJob, _ phase: ImportJob.Phase) {
        job.enter(phase)
        let message = phase.errorText ?? "Couldn't import \(job.displayName)"
        diagLogError("[IMPORT] \(job.displayName): \(message)")
        record(job, .failed(message))
    }

    private func record(_ job: ImportJob, _ outcome: ImportResult.Outcome) {
        results.append(ImportResult(
            id: job.id,
            sourceURL: job.sourceURL,
            outcome: outcome,
            finishedAt: now()
        ))
    }

    /// Session ids are second-resolution timestamps, so an id minted from the
    /// clock alone can collide two ways: with another import in the same second,
    /// and with a *live* session the user starts while the import runs — the
    /// engine would then open its own `<sid>.mic.wav` over the import's copy and
    /// interleave both sessions into one JSONL. The `-import` marker makes the
    /// second collision structurally impossible (live ids never carry it); the
    /// disk probe below handles the first.
    static func uniqueSessionId(in directory: URL) -> String {
        let base = "\(SessionStore.generateSessionId())-import"
        let taken: (String) -> Bool = { candidate in
            let fm = FileManager.default
            return fm.fileExists(atPath: directory.appendingPathComponent("\(candidate).mic.wav").path)
                || fm.fileExists(atPath: directory.appendingPathComponent("\(candidate).jsonl").path)
        }
        guard taken(base) else { return base }
        for suffix in 1...999 {
            let candidate = "\(base)-\(suffix)"
            if !taken(candidate) { return candidate }
        }
        return "\(base)-\(UUID().uuidString.prefix(8))"
    }
}
