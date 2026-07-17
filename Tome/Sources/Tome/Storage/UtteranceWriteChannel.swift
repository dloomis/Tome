import Foundation

/// Single-consumer channel that serializes utterance writes to the markdown
/// transcript (`TranscriptLogger`) and the JSONL crash-recovery journal
/// (`SessionStore`). Prevents the two stores from drifting out of order when
/// utterances finalize faster than the individual appends can run.
///
/// `flush()` is the stop-path barrier: it returns only after every write
/// queued before it has been applied to BOTH stores. `stopSession` calls it
/// between draining the transcribers and `endSession()` — which closes the
/// files — so the tail utterances land in the transcript instead of leaking
/// into the logger's buffer after the file handle is gone.
final class UtteranceWriteChannel: Sendable {
    private enum Message: Sendable {
        case write(speaker: Speaker, text: String, timestamp: Date)
        case flush(CheckedContinuation<Void, Never>)
    }

    private let continuation: AsyncStream<Message>.Continuation
    private let writerTask: Task<Void, Never>

    init(logger: TranscriptLogger, store: SessionStore) {
        let (stream, continuation) = AsyncStream.makeStream(of: Message.self)
        self.continuation = continuation
        self.writerTask = Task {
            defer { diagLog("[CHANNEL] utterance writer exited") }
            for await message in stream {
                switch message {
                case .write(let speaker, let text, let timestamp):
                    let speakerName = speaker == .you ? "You" : "Them"
                    await logger.append(speaker: speakerName, text: text, timestamp: timestamp)
                    await store.appendRecord(
                        SessionRecord(speaker: speaker, text: text, timestamp: timestamp))
                case .flush(let barrier):
                    barrier.resume()
                }
            }
        }
    }

    func write(speaker: Speaker, text: String, timestamp: Date) {
        continuation.yield(.write(speaker: speaker, text: text, timestamp: timestamp))
    }

    /// Returns once every write queued before this call has been applied to the
    /// logger and the session store. Safe after `shutdown()` (returns at once).
    func flush() async {
        await withCheckedContinuation { barrier in
            let result = continuation.yield(.flush(barrier))
            // Only an enqueued barrier will be resumed by the writer; a
            // terminated (or dropped) yield must resume here or the stop
            // path would hang forever.
            if case .enqueued = result {} else { barrier.resume() }
        }
    }

    /// Ends the channel; queued writes still drain before the writer exits.
    func shutdown() {
        continuation.finish()
    }
}
