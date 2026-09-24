# Source provenance

MoonAV1 is extracted from the AV1/AVIF implementation in [0717lee/pixelforge](https://github.com/0717lee/pixelforge).

- Source revision: [`6f0c711c54f89d34f3e2ef97cde7a0a45458583d`](https://github.com/0717lee/pixelforge/tree/6f0c711c54f89d34f3e2ef97cde7a0a45458583d).
- Extraction date: 2026-09-24.
- Source scope: root `av1*.mbt` and `avif*.mbt`, their image/byte-reading support, independent AV1/AVIF fixtures, reference generators and third-party notices.
- Original implementation and review history remains in PixelForge. The [source handoff](https://github.com/0717lee/pixelforge/blob/6f0c711c54f89d34f3e2ef97cde7a0a45458583d/HANDOFF.md) describes the original acceptance evidence.

The extraction creates an independent package and maintenance boundary. It does not make pre-existing decoding algorithms, tests or fixtures newly implemented work. Any competition or contribution report should identify this baseline and separately list work performed after extraction.

MoonAV1 remains a complete local independent repository: no public MoonAV1 repository has been created and no Mooncakes package has been published. PixelForge integration is paused. PixelForge retains its built-in decoder, public implementation history and existing codec entry points; it currently has no active MoonAV1 vendor or workspace dependency.

PixelForge migration commit `e366566e95b59173738bdb9bbbc5376550bd92cb` and snapshot-integration commit `cb8169b2495bdaee9d829515e4811639d096165c` were previously pushed with normal history. The snapshot used MoonAV1 revision `9f0f0c31a3ab35f169836223e6505b584882a15a`. These integration changes have been withdrawn through new revert commits, preserving their original history and validation evidence; see the [handoff](HANDOFF.md). The snapshot is not the current integration method.

This independent library retains all extracted source, tests, fixtures, reference generators and notices. A future PixelForge migration must follow MoonAV1's formal publication and consume a released version. Public hosting and package publication remain separate maintainer decisions, with no release date promised.

Algorithm and table sources include libaom, go-av1 and dav1d. Their notices are retained in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Fixture manifests retain encoder/decoder versions, commands, hashes and comparison conventions. Reference pixels are not regenerated merely to make migration tests pass.

The PixelForge-wide count of 1546 tests belongs to the original repository at the source revision. MoonAV1 has its own test count and verification record; these must not be conflated.
