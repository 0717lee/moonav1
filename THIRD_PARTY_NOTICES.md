# Third-party notices

## Development history

Early AV1/AVIF implementation and reference history is retained in
[PixelForge revision 6f0c711](https://github.com/0717lee/pixelforge/tree/6f0c711c54f89d34f3e2ef97cde7a0a45458583d).
MoonAV1 is maintained as an independent library.


## Real-media interoperability fixtures

`tests/fixtures/av1-diverse-video/` retains **Tears of Steel** media, (CC)
Blender Foundation | mango.blender.org, directed by Ian Hubert (2012), under
[CC BY 3.0](https://creativecommons.org/licenses/by/3.0/), as stated by the
[original project](https://mango.blender.org/about/). The complete source MOV,
including credits, is unchanged. Video test excerpts remove audio and record
their intervals, scaling and encoding. The separately retained `copyright.txt`
licenses the soundtrack, © Joram Letwory, under CC BY-ND 3.0; it is not the
video license. No soundtrack is present in derived codec fixtures.

The same directory retains eight **Sparks** HDR master TIFFs, Netflix Inc.
(2017), from [Netflix Open Content](https://opencontent.netflix.com/) under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The distribution's
complete license is preserved at `sources/sparks-license.txt`. PQ/HLG/YUV
conversion, scaling, encoder choices and source hashes are recorded.

`tests/fixtures/avif-real-images/` retains NASA's astronaut photograph,
Rachel Michetti's coffee image (CC0), Michae2109's public-domain Oslo sunset,
and Kumar Mangal Roy's Kolkata street-vendor photograph (CC0). Direct source
pages, credits and transformations are listed in its manifest and
[README](tests/fixtures/avif-real-images/README.md).
The AdobeCompat-v2 profile is from saucecontrol's
[Compact-ICC-Profiles](https://github.com/saucecontrol/Compact-ICC-Profiles),
dedicated under CC0. It is a retained fixture profile, not a runtime dependency.
The transparent illustration and browser pages are original test content,
explicitly identified separately from photographs.

These media and profile licenses remain distinct from the library source
license. Reference tools include Pillow/libavif, FFmpeg, SVT-AV1, rav1e,
libaom, AMD AMF, dav1d, LittleCMS and Playwright/Chromium. They are used locally
for generation or independent checking; the library does not invoke them.

## Big Buck Bunny test excerpt

`tests/fixtures/av1-realvideo/` contains a source excerpt and derived AV1, AVIF
and native reference frames from **Big Buck Bunny**.

`tests/fixtures/av1-long-containers/` also contains six container remuxes of that
retained AV1 excerpt. The added audio track is a locally generated 440 Hz sine;
the manifest records the FFmpeg commands and refers to the unchanged native
reference file instead of duplicating it.

(c) copyright 2008, Blender Foundation / www.bigbuckbunny.org.

The film is licensed under [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/),
as specified by the [original project](https://peach.blender.org/about/).
The source mirror, file hash, excerpt, scaling, re-encoding and removal of audio
are recorded in the corpus README and manifest. This media retains its own
license and is not relicensed as MoonAV1 source code.

## Color and container reference-tool boundary

The color-display fixture manifest records LittleCMS 2.19 as an independent
reference oracle through its public `cmsCreateTransform`/`cmsDoTransform` ABI;
see the [LittleCMS project](https://www.littlecms.com/). Its saved ICC profiles
are synthetic/project-owned reference inputs. No LittleCMS source, binary or
installed vendor profile is included as a MoonAV1 runtime dependency.

The AV1 container fixtures record FFmpeg and ffprobe versions and commands;
see the [FFmpeg project](https://ffmpeg.org/). FFmpeg/ffprobe are used only to
produce or inspect the retained IVF, MP4/fMP4 and WebM files and their packet
hashes. No FFmpeg or host container API is called by the library. The native
frame CRCs reuse the immutable dav1d reference described below; no additional
upstream codec source is copied into these generators or fixtures.

## LittleCMS intent and black-point algorithms

The intent fallback, fully adapted absolute media-white scaling and input
black-point compensation in `icc_color.mbt` are adapted from the algorithms
in LittleCMS 2.19 [`cmsio1.c`](https://github.com/mm2/Little-CMS/blob/lcms2.19/src/cmsio1.c),
[`cmscnvrt.c`](https://github.com/mm2/Little-CMS/blob/lcms2.19/src/cmscnvrt.c), and
[`cmssamp.c`](https://github.com/mm2/Little-CMS/blob/lcms2.19/src/cmssamp.c).
The pure MoonBit implementation does not link LittleCMS. The original source
is distributed under the MIT license:

Copyright (c) 1998-2026 Marti Maria Saguer

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## NASA photographic test input

`tests/fixtures/av1-maturity/apollo17-blue-marble.jpg` is NASA / Apollo 17 crew
photograph AS17-148-22727. Its original source, SHA-256, transformations and
attribution are recorded in that corpus's README and manifest. It is used as
factual decoder test material under NASA's media usage guidelines; it is not
relicensed as MoonAV1 source code and does not imply NASA endorsement.

## libaom reference algorithms

The AV1 CfL prediction and probability defaults in `av1_cfl.mbt`, directional
prediction in `av1_directional_predict.mbt`, and reference-availability tables
and rules in `av1_intra_edges.mbt`, and the deblocking kernels and traversal in
`av1_loop_filter.mbt` and `av1_loop_filter_frame.mbt`, and filter-intra prediction
in `av1_filter_intra.mbt`, and palette syntax and probability tables in
`av1_palette.mbt` and `av1_palette_index.mbt`, and the horizontal
super-resolution filter table and scalar convolution in `av1_superres.mbt`,
and the loop-restoration unit-count rule, configuration validation and grid
layout in `av1_restoration_config.mbt`
are transcribed from libaom at revision
`8e7b6a567df174d795479b92b4ac766d271add73`. The original source is available
at <https://aomedia.googlesource.com/aom/>. It uses the following BSD 2-Clause
License and the [Alliance for Open Media Patent License 1.0](https://www.aomedia.org/license/patent).

Copyright (c) 2016, Alliance for Open Media. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in
   the documentation and/or other materials provided with the
   distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

## go-av1 reference tables

The AV1 default CDF and quantizer tables in the `av1_*tables.mbt` files,
including the intra-mode tables and the `Subpel_Filters` interpolation kernels
in `av1_interp_tables.mbt`, were transcribed from corresponding tables in the
`github.com/mgvs/go-av1` project. The general sequence and frame-header grammar
(`av1_parse_sequence_payload`, `av1_parse_frame_prefix`, the reference-list
derivation and the global-motion sub-exponential coders) and the eight-tap
subpel motion-compensation kernel in `av1_mc.mbt` follow the same project's
`header/`, `decode/intermode.go` and `decode/mc.go` algorithms, and its
`decode/subpel_gen.go` source hash is pinned in the generated table header.
Correctness is settled against the AV1 specification and dav1d output rather
than against that implementation, and where the two disagree the specification
wins. It is distributed under the BSD 2-Clause License:

Copyright (c) 2026, Oleksandr Zhabotynskyi

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

## dav1d inverse quantization matrices

The AV1 inverse quantization matrix data in `av1_qmatrix_tables.mbt` is
transcribed from dav1d 1.2.1 `src/qm.c`. Matrix selection and coefficient
dequantization in `av1_qmatrix.mbt` and `av1_coeff_decode.mbt` follow AV1
sections 5.9.14 and 7.12.3 and are checked against dav1d's native C code.
`scripts/generate-av1-qmatrix.py` compiles the original matrix initialization
functions and the DC quantization-matrix branch from `src/recon_tmpl.c` to
generate the reference tests. It pins the SHA-256 of all reference sources;
the generated source retains the original copyright and license notice.
The SGR arithmetic checks in `av1_sgr_unsigned_reference_wbtest.mbt` are
generated by `scripts/generate-av1-sgr-reference.py`, compiling the original
`boxsum3`, `boxsum5`, and `selfguided_filter` routines from
`src/looprestoration_tmpl.c` and its `src/tables.c` lookup table. Both source
hashes are pinned; this verifies the unsigned statistics reproduced with
wide integer products in `av1_restoration_filter.mbt`.
The frame-edge correction to the warp-neighbour walk in `av1_warp_model.mbt`
also follows dav1d 1.2.1 `src/decode.c`, where `decode_b` clips scan extents to
the remaining frame area before `find_matching_ref`. The nominal block size
continues to describe warp geometry. Larger-image fixture manifests retain
the independent dav1d output and source/tool information for this correction.
The compound global-motion candidate correction in `av1_mv.mbt` was checked
against dav1d 1.2.1 `add_spatial_candidate` / `dav1d_refmvs_find` in
`src/refmvs.c` and `splat_tworef_mv` in `src/decode.c`. It applies the current
block centre independently to each affine/rotzoom reference before candidate
merging. The 1080p native reference, focused regressions and before/after record
are retained in the separate `av1-maturity` corpus and local benchmark results.
The translation branch now also applies forced-integer motion precision,
matching `get_gmv_2d` / `fix_int_mv_precision` in dav1d 1.2.1 `src/env.h`.
Its focused regression preserves the ordinary fractional-precision result.
The separate `tests/fixtures/av1-stream` corpus also uses dav1d 1.2.1 native
output, with libavif 0.11.1 checking the static AVIF. Its original synthetic
inputs, unmodified libaom streams, tool versions and commands are recorded in
that directory; no additional upstream decoder source is copied by its generator.
The skipped-inter deblocking edge correction in `av1_loop_filter_frame.mbt`
also follows AV1 §7.14.2 and dav1d 1.2.1 `src/lf_mask.c`: coding-block edges
remain eligible, while skipped inter blocks omit internal transform edges.

The original sources are available at
<https://code.videolan.org/videolan/dav1d/-/tree/1.2.1/src> and
<https://github.com/videolan/dav1d/tree/1.2.1/src> under the BSD 2-Clause License:

Copyright © 2018, VideoLAN and dav1d authors
Copyright © 2018-2021, VideoLAN and dav1d authors
Copyright © 2018, Two Orioles, LLC
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
