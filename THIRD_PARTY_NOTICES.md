# Third-party notices

The native application includes or derives from the following software. Distribution of a built application must include these notices and comply with the referenced licenses.

## Keraunos

- Project: https://github.com/LiLiKazine/Keraunos
- Pinned source commit: `863a436cfc3028f38ff8e1f940a66a3e68c53104`
- Source archive SHA-256: `a3c8a353a650ce79b51db58e798d0f81ef6ea34847e7eb4c6bbd532b0f63b8fc`
- License: GNU General Public License v3.0

The embedded Python resources, extraction bridge architecture, and bridge-derived source use Keraunos. The native application is distributed under GPLv3; the full license is in `LICENSE-GPL-3.0.txt`. The sanitized public build repository supplies the corresponding application source and reproducible asset acquisition scripts.

## yt-dlp and yt-dlp-ejs

Keraunos's pinned Python resources contain yt-dlp 2026.6.9 and yt-dlp-ejs 0.8.0. yt-dlp is dedicated to the public domain under the Unlicense. Individual dependencies and JavaScript components retain their own notices in the pinned source distribution.

## BeeWare Python Apple support

- Project: https://github.com/beeware/Python-Apple-support
- Release: `3.13-b14`
- iOS archive SHA-256: `8b5cb76ef8d8a2946052479358eeec9d54b4496cb60920e175ec1489b5cf7963`

The archive provides the embedded CPython XCFramework. CPython and the support package retain their upstream licenses.

## Argmax OSS Swift / WhisperKit

- Package version: `1.1.1`
- Resolved revision: `1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`

WhisperKit remains isolated behind the transcription interface. Model weights are downloaded only by an explicit user action and are not distributed in source or build artifacts.
