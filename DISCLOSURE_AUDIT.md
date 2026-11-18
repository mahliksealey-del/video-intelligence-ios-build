# Public disclosure audit

## Result

**Prepared and locally audited; not published.** Every proposed tracked file is listed in `SOURCE_ALLOWLIST.txt`. The snapshot contains no detected credentials, signing assets, private media, personal transcripts, model weights, generated Apple projects, build output, local absolute paths, or private PWA source.

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
- `Package.resolved`: absent until the first authorized bootstrap run generates and verifies the genuine file.

## Remaining publication review

The owner must review the exact allowlist and this report before repository creation or the first public push. Native compilation and dependency graph completeness remain unverified until the separately authorized macOS runner execution.
