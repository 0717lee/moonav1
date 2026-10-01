# Real media and encoder interoperability

This corpus retains independently encoded AV1, original container exports,
unmodified dav1d native planes, syntax traces, commands, and source hashes.
`manifest.json` records eleven cases. `container-manifest.json` records the ten
video cases in MP4 and an additional WebM representation of the VFR case.
The browser case uses actual Chromium screenshots of explicitly synthetic,
project-owned page content. External encoders and decoders are fixture tools;
the MoonAV1 consumer performs all decoding in MoonBit.

| Case | Encoder | Native output | Presentations |
| --- | --- | --- | ---: |
| `tos_svt8_640x360` | SVT-AV1 | 640×360, 8-bit 4:2:0 SDR | 96 |
| `tos_rav1e10_640x360` | rav1e | 640×360, 10-bit 4:2:0 SDR | 64 |
| `tos_amf8_640x360` | AMD AMF / Radeon 780M | 640×362, 8-bit 4:2:0 SDR | 96 |
| `tos_rav1e12_444_320x180` | rav1e | 320×180, 12-bit 4:4:4 SDR | 32 |
| `tos_vfr_svt8_512x288` | SVT-AV1 | 512×288, 8-bit 4:2:0 SDR, varying PTS gaps | 120 |
| `tos_long_svt8_1280x720` | SVT-AV1 | 1280×720, 8-bit 4:2:0 SDR | 4320 |
| `sparks_pq10_svt_512x270` | SVT-AV1 | 512×270, 10-bit 4:2:0 PQ | 8 |
| `sparks_hlg10_rav1e_512x270` | rav1e | 512×270, 10-bit 4:2:0 HLG | 8 |
| `sparks_pq12_still_512x270` | libaom | 512×270, 12-bit 4:2:0 PQ, AVIF also retained | 1 |
| `sparks_4k60_amf10_4096x2160` | AMD AMF / Radeon 780M | 4096×2160, 10-bit 4:2:0 PQ | 8 |
| `browser_rav1e8_444_768x512` | rav1e | 768×512, 8-bit 4:4:4 SDR | 96 |

The three-minute case is a continuous 180-second selection at 24 fps from
Tears of Steel, starting at 90 seconds; it does not replay a short sequence.
The original film file is 1280×534. Test exports preserve that picture's aspect
ratio and letterbox it to the stated canvas. The source has no CICP tags; the
conversion explicitly interprets/signals BT.709. Its 10/12-bit derivatives do
not claim higher-bit-depth camera capture or HDR.

Sparks TIFFs 1200–1207 are contiguous original 4096×2160 RGB16 frames from the
BT.2020/PQ 1000-nit HDR master. They are sampled at the source's 60000/1001 fps.
The 4K case is therefore a short eight-frame high-rate test, not a multi-minute
4K soak. HLG is a documented conversion from the PQ master. All transformations
and their signaled CICP values are retained in each `.case.json`.

The AMF 8-bit original export requests 640×360 but encodes a sequence whose
native maximum is 640×362. Its original MP4 incorrectly keeps 640×360 in the
`av01` sample entry, contrary to [AV1 ISOBMFF §2.2.4](https://aomediacodec.github.io/av1-isobmff/#av1-sample-entry-semantics).
That file is retained as rejection evidence. A separately named `.remux.mp4`
is a real FFmpeg stream-copy export with a 640×362 sample entry. The generator
checks every AV1 packet hash, size, timestamp, duration and sync flag before
accepting the remux. No encoded packet or native reference is patched.

## Sources and rights

- **Tears of Steel**, (CC) Blender Foundation | mango.blender.org, directed by
  Ian Hubert (2012), [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).
  See the [project](https://mango.blender.org/about/) and
  [original download page](https://mango.blender.org/download/).
  `sources/downloads.json` records the NJU mirror URL and SHA-256 of the complete
  original MOV, including its credit roll. Excerpts remove audio and are scaled
  and re-encoded solely as codec test material. The retained `copyright.txt`
  concerns the **soundtrack**, © Joram Letwory, CC BY-ND 3.0; it is not the
  film's video license. The original MOV remains unmodified.
- **Sparks**, Netflix Inc. (2017), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/),
  from [Netflix Open Content](https://opencontent.netflix.com/).
  Eight original TIFFs and the distribution's complete multilingual license
  are retained in `sources/`, with direct source URLs and hashes.
- **Browser recording**: original test dashboard, captured locally with
  Playwright/Chromium. Its retained `page.html`, `mutation.js`, 96 PNGs and
  `capture.json` identify the exact page, deterministic changes, browser,
  platform and capture options. The capture record declares the test media's
  CC0 dedication, matching the source page. It is not a recording of a production application.

Media keeps these licenses independently of the library's Apache-2.0 source
license. No association with or endorsement by the media authors is implied.

## References and checks

Native reference files contain tightly packed Y, U, V planes in display order;
8-bit samples occupy one byte and 10/12-bit samples occupy unshifted little-endian
uint16. Comparison requires every native sample to match. A large reference is
read and hashed incrementally; the three-minute reference is about 5.97 GB.
It is permanent independent evidence, not a disposable build artifact.

```sh
python scripts/generate-diverse-video-reference.py --check
python scripts/generate-diverse-video-reference.py --check --redecode
python scripts/generate-diverse-video-reference.py --check --containers
python scripts/check-file-fixtures.py --manifest tests/fixtures/av1-diverse-video/manifest.json --target-dir _build/slop-file --timeout 7200
python scripts/check-long-containers.py --manifest tests/fixtures/av1-diverse-video/container-manifest.json --target-dir _build/slop-file --timeout 7200 --chunk-seed 20260929
```

The first check reads retained evidence; `--redecode` runs dav1d again into a
temporary file and compares its hash, never replacing the saved reference.
`--check --containers` reruns independent ffprobe packet and decoded-frame
inspection, confirms one presentation per packet, and checks MP4 structure.
WebM duration comes from exact `DefaultDuration`/`BlockDuration` nanoseconds,
not ffprobe's rounded millisecond duration or a guessed difference between PTS.
Ordinary MoonBit file-consumer checks use saved evidence without external codecs.

Generation resumes only completed, hash-checked cases and refuses to overwrite
completed manifests. The container-only generation mode is `--containers`.
Ordinary source/native reference bytes are never changed to make MoonAV1 pass.
Encoder binaries, drivers, fonts and browser versions can affect newly generated
files; their recorded outputs and hashes are the reproducibility boundary.
