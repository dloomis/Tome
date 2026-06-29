# Roadmap

## Up next

**Custom vocabulary boosting**
Decode-time vocabulary biasing via CTC keyword spotting. Feed a JSON file of domain-specific terms and the transcriber prioritizes those words. No retraining needed.

**FluidAudio fork**
Upstream fixes to the ASR pipeline: source-specific decoder state reset and a thread safety improvement.

**JSONL crash recovery**
Rebuild transcripts from session data if the app exits mid-session.

**Meeting autodetection**
Detect the active meeting in Google Meet, Microsoft Teams, or Zoom. Shipped: the detected meeting name auto-fills the Call Capture filename, shown as a dismissible chip (see `docs/meeting-detection.md`). Still planned: automatically prompt to start recording when a meeting begins — no manual capture toggling.

**Multi-language support**
Transcription currently defaults to English. Add a language picker so sessions can be transcribed in other languages.

**Stealth mode**
Hide the Tome app from screen capture so it doesn't appear when sharing your desktop during a meeting.
