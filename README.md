# Video Intelligence public iOS build snapshot

This repository is a minimal, independently buildable snapshot of the native Video Intelligence foundation. It contains only the SwiftUI application target, transcript contract and tests, XcodeGen project specification, unsigned packaging and verification scripts, and a manually dispatched public build workflow.

It is not a mirror of the private development repository and contains none of the existing browser/PWA application.

## Build policy

- The workflow runs only through **Actions → Video Intelligence Public iOS Build → Run workflow**.
- It uses the standard `macos-15` runner, Xcode 16.4, and integrity-verified XcodeGen 2.47.0.
- Repository permissions are read-only and external GitHub actions are pinned to immutable commit SHAs.
- The `WhisperKit` product is locked to exact Argmax OSS Swift version 1.1.1 at revision `1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`.
- Native contract tests run on an iOS Simulator before an unsigned ARM64 device build is packaged.
- The generated application is checked for architecture, metadata, unsigned state, prohibited media/model files, and provisioning profiles.
- `VideoIntelligence-unsigned.ipa` is a Sideloadly signing input, not a directly installable application.
- Build evidence and artifacts expire after seven days.

## Dependency modes

Authorized bootstrap run `44351596420` generated and verified the genuine `Package.resolved`, recovered from artifact `14447624823`. It is committed at the repository root; all later builds use the default `locked` mode and fail unless the generated workspace lockfile matches it exactly.

## Static-review corrections

Before the first hosted build, an independent source review corrected the `SWIFT_VERSION` build setting to `5` (the Swift 5 language mode) and specified the test fixture folder in XcodeGen's `sources` with `buildPhase: resources`. Build #1 then exposed XcodeGen's default test-host path using the target name instead of the preserved product name. The test target now explicitly uses `VideoIntelligence.app/VideoIntelligence` through `TEST_HOST` and `BUNDLE_LOADER`; the app name remains unchanged.

Build #3 showed that preserving product name `VideoIntelligence` also changed the default Swift module name, so the tests could not import `VideoIntelligenceNative`. The app now explicitly sets `PRODUCT_MODULE_NAME` to `VideoIntelligenceNative`. A generated build-settings preflight fails before simulator compilation unless the product, executable, module, wrapper, test host, and bundle loader agree.

## Local limitations

Windows can audit this snapshot but cannot compile native iOS code. GitHub runner compilation is authoritative. Simulator and unsigned-build success do not establish signing, installation, iOS 26.6.2 compatibility, on-device memory behavior, or transcription inference.

Whisper model weights are not included in this snapshot. Phase 2 adds an explicit in-app model download and real local inference path; device-only performance and inference acceptance remain pending.

## Phase 2 native media library

The snapshot now contains unified Files, Photos, and direct-URL ingestion; AVFoundation audio extraction; persistent user-visible storage; explicit `base.en` model download; real WhisperKit inference; playback with timestamp seeking; separate transcript corrections; and TXT, SRT, JSON, and PDF export.

iOS File Sharing exposes `Videos`, `Audio`, `Transcripts`, and `Exports` directly under Files → On My iPhone → Video Intelligence. The private library index and regenerable model weights remain in Application Support.

URL ingestion accepts accessible direct HTTP(S) media resources. It does not scrape webpages or bypass authentication, streaming restrictions, or DRM. A Share extension is deferred because it requires a second signed target and App Group migration; Files, Photos, URL paste, and export sharing are implemented.

Hosted tests use deterministic mocks around service boundaries. Actual model download, A15 inference, offline behavior, thermal performance, Photos memory behavior, and long-recording behavior require physical-device validation after installation.

## Phase 3 reliability

Phase 3 adds Fast, Balanced, and Accurate profiles (`base.en`, tuned `base.en`, and `small.en`), verified model asset discovery, free-space checks, retry/cancel/delete controls, persistent engine reuse, cold/warm timing, deterministic WER calculation, memory-pressure unloading, and exportable sanitized diagnostics. Balanced remains the default pending repeatable A15 benchmarks.

Playback now uses the system playback audio category, AVPlayerViewController for video, an explicit draggable timeline, elapsed/total time, ±15-second seek, transcript timestamp seek, rate selection, end-state handling, and visible player errors.

Direct downloads reject unsafe local-address literals, excessive files, text responses, and unsafe final redirect destinations. YouTube, TikTok, and Instagram URLs are detected but not falsely claimed as supported. Reliable on-device extraction requires an embedded Python/yt-dlp/JavaScript/muxing stack and unresolved binary/licensing review; this snapshot neither sends links to conversion sites nor bundles unaudited runtimes.

## Publication boundary

`SOURCE_ALLOWLIST.txt` is the exact permitted tracked-file inventory. The workflow runs `scripts/audit-public-snapshot.sh` before installing tools or resolving dependencies. See `DISCLOSURE_AUDIT.md` and `SOURCE_PROVENANCE.md` for the reviewed disclosure boundary and source mapping.

## Source and licensing

Third-party dependencies are retrieved by Swift Package Manager under their respective upstream licenses; their source and model weights are not vendored here. Publication of this snapshot does not itself grant permission to use, modify, or redistribute the first-party source unless the owner adds an explicit license.
