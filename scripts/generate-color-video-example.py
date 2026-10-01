#!/usr/bin/env python3
"""Embed retained inputs for the public color/video example; --check is read-only."""
import argparse
from pathlib import Path
import subprocess
import struct

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'examples/color_video/fixtures.mbt'
INPUTS = {
    'metadata_fixture': 'extensions/metadata_8_r0_m0.avif',
    'hdr_obu': 'av1-color/ictcp_pq_444_10bit.obu',
    'container_ivf': 'av1-containers/reorder_prefix8_10bit_320x180.ivf',
    'container_mp4': 'av1-containers/reorder_prefix8_10bit_320x180.mp4',
    'container_webm': 'av1-containers/reorder_prefix8_10bit_320x180.webm',
}


def source():
    chunks = ['''/// Generated from retained fixtures by scripts/generate-color-video-example.py.
/// No host decoder participates in this public consumer.
///|
fn fixture_bytes(rows : Array[String]) -> Array[Byte] {
  let result : Array[Byte] = []
  for row in rows {
    let chars = row.to_array()
    for i in 0..<(chars.length() / 2) {
      let high = chars[i * 2].to_int()
      let low = chars[i * 2 + 1].to_int()
      result.push((((if high >= 97 { high - 87 } else { high - 48 }) << 4) |
        (if low >= 97 { low - 87 } else { low - 48 })).to_byte())
    }
  }
  result
}
''']
    for name, relative in INPUTS.items():
        data = (ROOT / 'tests/fixtures' / relative).read_bytes()
        derivation = ''
        if name == 'metadata_fixture':
            # Retain encoded color/alpha exactly; demonstrate a fractional
            # clean aperture without changing the original reference file.
            marker = bytes.fromhex('00000028636c6170')
            if data.count(marker) != 1:
                raise SystemExit('Expected one 40-byte clap property')
            at = data.index(marker) + len(marker)
            if struct.unpack_from('>IIIIiIiI',data,at) != (12,1,10,1,-1,1,1,1):
                raise SystemExit('Unexpected retained clean-aperture fields')
            changed = bytearray(data)
            struct.pack_into('>IIII',changed,at,23,2,19,2)
            data = bytes(changed)
            derivation = '; clap width=23/2 and height=19/2, other bytes retained'
        rows = '\n'.join('    "'+data[i:i+60].hex()+'",' for i in range(0,len(data),60))
        chunks.append(f'///|\n/// Source: tests/fixtures/{relative}{derivation}\nfn {name}() -> Array[Byte] {{\n  fixture_bytes([\n{rows}\n  ])\n}}\n')
    return subprocess.run(['moonfmt','-'],input='\n'.join(chunks),capture_output=True,
                          text=True,encoding='utf8',check=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check',action='store_true')
    args = parser.parse_args()
    expected = source()
    if args.check:
        if OUTPUT.read_text(encoding='utf8') != expected:
            raise SystemExit('Color/video example fixture bytes differ')
        print('Color/video example: five inputs match retained sources and the declared fractional clap derivation')
    else:
        OUTPUT.write_text(expected,encoding='utf8',newline='\n')


if __name__ == '__main__':
    main()
