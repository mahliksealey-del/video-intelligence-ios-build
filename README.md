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

Direct downloads reject unsafe local-address literals, excessive files, text responses, and unsafe final redirect destinations. YouTube, YouTube Shorts, TikTok, Instagram Reel, and Instagram post URLs now use the embedded CPython/yt-dlp extractor, native URLSession transfers, and AVFoundation adaptive-stream merging. Video, audio, and download-and-transcribe actions converge on the existing library. Authentication, DRM, and access controls are not bypassed. Runtime inputs are pinned and SHA-256 verified by `scripts/prepare-social-runtime.sh`; generated runtime files remain untracked. Live provider behavior and playback still require physical-device validation.

## Publication boundary

`SOURCE_ALLOWLIST.txt` is the exact permitted tracked-file inventory. The workflow runs `scripts/audit-public-snapshot.sh` before installing tools or resolving dependencies. See `DISCLOSURE_AUDIT.md` and `SOURCE_PROVENANCE.md` for the reviewed disclosure boundary and source mapping.

## Source and licensing

This native application includes Keraunos-derived GPLv3 components and is distributed under GPLv3. See `LICENSE-GPL-3.0.txt` and `THIRD_PARTY_NOTICES.md` for exact sources, revisions, hashes, and other upstream licenses. Model weights are not vendored.


## UMR-2: Embedded video and built-in ad blocking (experimental)

The **feature/universal-frame-media-detection-2026-11-20** branch extends the successful UMR-1 browser to recognize video inside nested, cross-origin iframe players. After you play a video, tap **Find Video**. A user-initiated per-frame WebKit script collects playable HTTPS links and HLS/DASH manifests. The frame's URL is verified from the WebKit message metadata and an unpredictable scan identifier. If a player link is found without a direct file, tap **Open Player** and try playback / Find Video again. Direct video files still save to the existing library. HLS/DASH export, DRM-protected video and opaque blob/MSE playback are **not promised or implemented in UMR-2**.

**New controls:** **Block Ads** is on by default and compiles a conservative local list of third-party advertising hosts using Apple's WKContentRuleListStore. It is intentionally much smaller than Firefox's full uBlock Origin filter engine. Turn it off if an ad-filtering false positive breaks playback or sign-in; the current webpage reloads. **Stay on Site** is off by default; turn it on after arriving at a video page to stop cross-host top-window redirects (including many ad hijacks) while still allowing iframe videos and media requests. Turn it off to follow legitimate links and logins. The original Dismiss Popup control and unsolicited new-window blocker remain. No jailbreaking, browser extension installation, subscription, outside service or cloud resolver is required.

**Open-source references evaluated, not copied:** [uBlock Origin](https://github.com/gorhill/uBlock), [EasyList](https://github.com/easylist/easylist), [AdGuard SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib), [1Blocker filter lists](https://github.com/1Blocker/Filters), and [WebKit rule-list documentation](https://developer.apple.com/documentation/webkit/wkcontentruleliststore). AdGuard/EasyList filtering is a much wider project involving filter syntax conversion, license retention, list updates and breakage tests. This build uses an independently authored small host list only; it does not bundle upstream list data or uBlock's source code.

## Universal Media Resolver UMR-1 (experimental)

The new `feature/universal-browser-resolver-2026-11-20` branch includes a user-driven `Website Browser` for public and authorized signed-in pages. Enter an unfamiliar webpage in **Get Media**, select **Download Video / Audio / Download & Transcribe**, choose **Open Website**, play video and tap **Find Video**. The scanner shows direct-video candidates, HLS playlists and DASH manifests when discoverable. An explicit **Dismiss Popup** button attempts to press a visible close/dismiss button on ordinary webpage overlays; it never automatically accepts consent or removes login, payment, age-verification or CAPTCHA gates. Unsolicited new-window popups are ignored; a user-tapped HTTPS link may open in the current browser. Normal website redirects and all forms of overlays are not guaranteed to be blocked. For a detected HTTPS direct video, **Save** uses the existing on-device media transfer, playable-file verification, library and transcript workflow. Cross-origin embedded players can be invisible to WebKit scripting; manifest-backed HLS/DASH exports, DRM, `blob:`/MSE media, and videos requiring non-cookie authentication are **not promised or implemented yet**. Browser cookie import is strictly scoped to domains matching both the viewed page and media host; cross-origin CDNs receive no originating-site login cookies.

Direct MP4/audio URLs retain the previous import route, while YouTube/Instagram retain yt-dlp and TikTok retains its user-verified dedicated WebKit route. Stable source and installed IPA remain unaffected until device acceptance. Test on a site whose video you are authorized to save; do not provide private URLs or cookies in bug reports.

## Experimental full-precision Whisper Large V3 (opt-in)

Branch `feature/whisper-full-large-v3-2026-11-20` adds a separate **Large V3 (Full Precision)** transcription profile using Argmax Core ML folder `openai_whisper-large-v3` (approximately 3.09 GB). It remains distinct from Medium English (`medium.en`, around 1.53 GB), the compressed full-Large-V3 model (`openai_whisper-large-v3_947MB`, **not** selected here), and the existing compressed Large V3 Turbo profile (`large-v3-v20240930_626MB`, approximately 626 MB). Model weights are downloaded by the user from the iPhone Settings screen and are **never included in the IPA**.

Full Large V3 and the compressed Turbo experiment require a device reporting at least 8 GB of physical RAM and free storage preflight of 8 GB / 3 GB respectively. Medium has a separate 4 GB free-storage preflight; base.en and small.en remain the default options. These are conservative eligibility checks, not proof that the larger models will load or finish on every device. An 8 GB device may still be terminated for memory pressure. Compare a representative short clip on all profiles before using full Large V3 for long recordings.

**Build/test procedure:** Manually dispatch **Video Intelligence Public iOS Build** against the `feature/whisper-full-large-v3-2026-11-20` branch with `dependency_mode=locked`. After tests, ARM64 build and unsigned IPA packaging pass, download the build artifact, extract `VideoIntelligence-unsigned.ipa`, and sign/install with Sideloadly. Keep the existing working release backed up until the physical device accepts download, inference, transcription quality, export and app restarts. Do not promote this research branch to stable without device evidence.

**Implementation note:** The pinned WhisperKit 1.1.1 downloader uses glob matching. Passing the exact prefixed model folder `openai_whisper-large-v3` is critical: the shorter string `large-v3` can ambiguously match full, compressed and Turbo model folders. The app's cached-model search also requires exact folder identity.
