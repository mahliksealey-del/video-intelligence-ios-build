# Third-party notices

The native application includes or derives from the following software. Distribution of a built application must include these notices and comply with the referenced licenses.

## Keraunos

- Project: https://github.com/LiLiKazine/Keraunos
- Pinned source commit: `863a436cfc3028f38ff8e1f940a66a3e68c53104`
- Source archive SHA-256: `a3c8a353a650ce79b51db58e798d0f81ef6ea34847e7eb4c6bbd532b0f63b8fc`
- License: GNU General Public License v3.0

The embedded Python resources, extraction bridge architecture, and bridge-derived source use Keraunos. The native application is distributed under GPLv3; the full license is in `LICENSE-GPL-3.0.txt`. The sanitized public build repository supplies the corresponding application source and reproducible asset acquisition scripts.

## yt-dlp and yt-dlp-ejs

Video Intelligence starts with the pinned Keraunos source at commit `863a436cfc3028f38ff8e1f940a66a3e68c53104` and replaces its embedded yt-dlp source at build time with the official `yt-dlp 2026.10.26` release (`yt-dlp.tar.gz`, SHA-256 `21f942d258d25cc4e60b4982a25c423460f0bebb835f38e6dfd1fcb140087f95`). The YouTube EJS 0.8.0 challenge-solver JavaScript library is acquired from [yt-dlp/ejs](https://github.com/yt-dlp/ejs/releases/tag/0.8.0) with official SHA-256 `770831df5c46474fbff06732315b28f4fb090e427ca669a51da61e2457d41c82`, and verified again against yt-dlp's vendor SHA3-512 manifest. The JavaScriptCore bridge is derived from the pinned Keraunos source. The yt-dlp and yt-dlp-ejs projects are dedicated to the public domain under the Unlicense. Third-party code and runtime components retain their respective notices and licenses; these dependencies are acquired during the verified CI build, not committed into the application source snapshot.

## BeeWare Python Apple support

- Project: https://github.com/beeware/Python-Apple-support
- Release: `3.13-b14`
- iOS archive SHA-256: `8b5cb76ef8d8a2946052479358eeec9d54b4496cb60920e175ec1489b5cf7963`

The archive provides the embedded CPython XCFramework. CPython and the support package retain their upstream licenses.

## Argmax OSS Swift / WhisperKit

- Package version: `1.1.1`
- Resolved revision: `1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`

WhisperKit remains isolated behind the transcription interface. Model weights are downloaded only by an explicit user action and are not distributed in source or build artifacts.

## hls2mp4 / minimp4 — source-based HLS MP4 experiment

- Upstream: https://github.com/cstsortan/hls2mp4
- Pinned source commit: 2e3adcbc95c689be2ff66d854ce38675e988eb17 (2026-03-19)
- License: MIT; retained in VideoIntelligenceNative/MediaProcessing/HLSRemux/LICENSE-MIT.txt
- minimp4 by lieff: public-domain notice preserved in minimp4.h.
- Vendored code: HLS playlist parser, MPEG-TS demuxer, H.264/AAC MP4 muxer and C headers.
- Video Intelligence authors replaced upstream libcurl and mbedTLS platform modules with native Foundation URLSession (http.m) and CommonCrypto (aes.m), with HTTPS redirect checks and bounded requests.
- Source-based, user-selected VOD m3u8 to a new MP4 only; Apple's offline movpkg is never modified.
- MPEG-TS path supports H.264/AAC; a separate Swift path handles basic unencrypted fMP4/CMAF.
- No libcurl, mbedTLS, or upstream native binary is shipped with this experiment.
- MIT code is included in the GPLv3 application with preserved notices.
