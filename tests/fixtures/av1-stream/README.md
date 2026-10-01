# Reordered AV1 source reference

This directory retains the original `reorder_10bit_320x180` case used by the
[container references](../av1-containers/README.md): 32 presentations at 25 fps,
including inter frames, hidden pictures and show-existing headers.

The source is a project-owned synthetic integer scene. The input YUV, encoded
OBUs, dav1d native reference and header trace are unchanged. `manifest.json`
retains this case's original commands, tool versions, metadata and hashes;
unrelated large-image cases are omitted from this distribution.

FFmpeg/libaom produced the encoded stream; dav1d 1.2.1 produced the independent
10-bit planar reference. The container tests reuse the first eight presentations.
Run `python scripts/generate-container-reference.py --check` from the repository
root to check container records, reference CRCs and the embedded tests without
regenerating pixels. This check requires ffprobe; ordinary `moon test` does not.
