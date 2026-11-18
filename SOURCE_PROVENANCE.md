# Source provenance

- Private source repository: `mahliksealey-del/mobile-video-transcriber`
- Source branch: `experiment/native-ios-a15-transcription-spike`
- Audited source commit: `45d26fb94cf80b8b0a78dfc598ae670fce2deb5f`
- Preserved release ancestor: `a22fbcd8725594519f8931b61856c026538a63fe`

The native application sources, tests, fixture, and four build helpers were copied from the audited source commit. The project specification was adapted for the public build and subsequently received two review corrections: Swift language mode `5` (rather than invalid `5.10`) and an explicit XcodeGen test-fixture resource entry. Public-only changes include:

- neutral bundle identifier `com.example.videointelligence.nativeprototype`;
- repository-root paths instead of the private repository's `NativePrototype/` prefix;
- public snapshot audit, provenance, instructions, allowlist, ignore rules, and workflow registration;
- removal of experiment-branch guards that apply only to the private repository, replaced by an exact public allowlist audit.

No private Git objects or history are part of this repository.
