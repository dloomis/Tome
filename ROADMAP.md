# Roadmap

## Up next

**Custom vocabulary boosting**
Decode-time vocabulary biasing via CTC keyword spotting. Feed a JSON file of domain-specific terms and the transcriber prioritizes those words. No retraining needed.

**FluidAudio fork**
Upstream fixes to the ASR pipeline: source-specific decoder state reset and a thread safety improvement.

**JSONL crash recovery**
Rebuild transcripts from session data if the app exits mid-session.

**Meeting autodetection**
Automatically detect when a meeting starts in Google Meet, Microsoft Teams, or Zoom and prompt to start recording — no manual capture toggling.

**Multi-language support**
Transcription currently defaults to English. Add a language picker so sessions can be transcribed in other languages.
