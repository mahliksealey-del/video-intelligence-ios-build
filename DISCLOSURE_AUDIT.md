# Public disclosure audit

## Result

**Published and locally audited.** Every tracked file is listed in `SOURCE_ALLOWLIST.txt`. The snapshot contains no detected credentials, signing assets, private media, personal transcripts, model weights, generated Apple projects, build output, local absolute paths, or private PWA source.

## Included

- Minimal SwiftUI application and local audio-picker state
- Transcript `Codable` contract and timestamp validation
- Deterministic harmless JSON fixture and native tests
- XcodeGen project specification with exact Argmax OSS Swift 1.1.1 dependency
- Manual public build workflow
- Tool-integrity, package-lock, simulator-selection, application-verification, packaging, and disclosure-audit scripts
- Minimal public instructions, provenance, allowlist, and ignore rules

## Explicitly excluded

- All browser/PWA source, assets, service workers, Cloudflare configuration, JavaScript dependencies, and web deployment documentation: unrelated to the native build.
- Private repository Git history, branches, tags, remotes, and Git metadata: the public snapshot must not be a mirror.
- Private development and planning documents: not required to compile or verify the native target.
- Apple credentials, certificates, provisioning profiles, private keys, and signing identities: cloud output is deliberately unsigned.
- Media, transcripts, downloads, caches, and model weights: private or unnecessary build inputs.
- Generated `.xcodeproj`, DerivedData, test results, IPA files, and other build output: generated only by the runner and retained as short-lived artifacts.
- Existing private-repository workflow: replaced by a public-root adaptation without private default-branch bootstrap logic.
- Personal bundle identifier: replaced with the neutral identifier `com.example.videointelligence.nativeprototype`.
- `Package.resolved`: the genuine file generated and verified by authorized bootstrap run `44351596420`, artifact `14447624823`, is included; no dependency source is vendored.

## Independent archive review (November 18, 2026)

The portable source archive was independently inspected. The 23 tracked publication paths matched the allowlist, shell scripts passed Bash syntax checks, the public snapshot audit passed against a temporary fresh Git commit, and platform-independent Swift types passed `swiftc -typecheck` on Linux. The review corrected the project configuration's invalid `SWIFT_VERSION: "5.10"` value to Swift 5 language mode and made the JSON test-fixture resource inclusion explicit through XcodeGen `sources` / `buildPhase: resources`. These checks are not a substitute for macOS/Xcode compilation or iPhone device testing.

Build #1 resolved and verified the dependency lock, generated the Xcode project, and reached native test invocation. It failed before compilation because XcodeGen derived a test host from the target name while the preserved app product/executable is `VideoIntelligence`. The public and private project specifications now explicitly set the correct test host without renaming the app.

## Remaining publication review

The corrected snapshot still requires a separately authorized locked macOS run to verify native compilation, tests, and unsigned device packaging. This correction does not claim Build #2 success.
