#!/usr/bin/env python3
"""Build and verify a small corpus of real, application-exported AVIF images.

The corpus is intentionally file-backed. Generation uses only local source
files (external photos and the ICC profile are acquired separately and then
retained beside the derived files); ordinary ``--check`` never downloads or
writes anything. Every saved AVIF is decoded again with the pinned libavif
library, and its tightly packed native planes are stored as the reference.
"""
from __future__ import annotations

import argparse
import ctypes as C
import hashlib
import io
import importlib.metadata
import importlib.util
import json
from pathlib import Path
import shutil
import sys
from typing import Any

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tests" / "fixtures" / "avif-real-images"
DEFAULT_LIBAVIF = Path(r"D:\ProgramData\anaconda3\Library\bin\avif.dll")
PROFILE_URL = (
    "https://raw.githubusercontent.com/saucecontrol/Compact-ICC-Profiles/"
    "master/profiles/AdobeCompat-v2.icc"
)
PROFILE_REPO = "https://github.com/saucecontrol/Compact-ICC-Profiles"
STREET_URL = (
    "https://upload.wikimedia.org/wikipedia/commons/a/a9/"
    "Street_photography.jpeg"
)
STREET_PAGE = "https://commons.wikimedia.org/wiki/File:Street_photography.jpeg"
LANDSCAPE_URL = "https://upload.wikimedia.org/wikipedia/commons/b/b8/Landscape_picture.JPG"
LANDSCAPE_PAGE = "https://commons.wikimedia.org/wiki/File:Landscape_picture.JPG"


def load_helper(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load helper {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


animation = load_helper("real_image_animation", "generate-avif-animation-alpha-reference.py")


class FullImage(C.Structure):
    _fields_ = animation.Image._fields_ + [
        ("owns_alpha", C.c_int),
        ("premultiplied", C.c_int),
        ("icc", animation.RWData),
        ("primaries", C.c_uint16),
        ("transfer", C.c_uint16),
        ("matrix", C.c_uint16),
    ]


SVG_SOURCE = """<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"512\" height=\"512\" viewBox=\"0 0 512 512\">
  <defs>
    <linearGradient id=\"sky\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\">
      <stop offset=\"0\" stop-color=\"#5ec8ff\"/><stop offset=\"1\" stop-color=\"#e9f7ff\"/>
    </linearGradient>
    <linearGradient id=\"glass\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\">
      <stop offset=\"0\" stop-color=\"#ffffff\" stop-opacity=\".86\"/>
      <stop offset=\"1\" stop-color=\"#c3e9f7\" stop-opacity=\".2\"/>
    </linearGradient>
  </defs>
  <circle cx=\"256\" cy=\"256\" r=\"224\" fill=\"url(#sky)\"/>
  <path d=\"M48 352 Q150 286 256 352 T464 352 V480 H48Z\" fill=\"#1d6b55\" opacity=\".9\"/>
  <path d=\"M48 392 Q150 332 256 392 T464 392 V480 H48Z\" fill=\"#174a3b\"/>
  <g transform=\"translate(148 132)\">
    <path d=\"M0 12 Q0 0 12 0 H204 Q216 0 216 12 V238 Q216 250 204 250 H12 Q0 250 0 238Z\" fill=\"url(#glass)\" stroke=\"#14506a\" stroke-width=\"8\"/>
    <path d=\"M-16 12 H232\" stroke=\"#14506a\" stroke-width=\"12\" stroke-linecap=\"round\"/>
    <path d=\"M42 64 H174 M42 111 H174 M42 158 H174\" stroke=\"#2d83a1\" stroke-width=\"9\" stroke-linecap=\"round\" opacity=\".86\"/>
    <path d=\"M73 0 V250 M143 0 V250\" stroke=\"#14506a\" stroke-width=\"6\" opacity=\".65\"/>
  </g>
  <circle cx=\"408\" cy=\"98\" r=\"25\" fill=\"#ffd166\"/>
  <circle cx=\"408\" cy=\"98\" r=\"38\" fill=\"none\" stroke=\"#ffd166\" stroke-width=\"5\" opacity=\".4\"/>
</svg>
"""

WEBPAGE_SOURCE = """<!doctype html>
<html><head><meta charset=\"utf-8\"><style>
  :root { color-scheme: light; font-family: Arial, sans-serif; }
  * { box-sizing: border-box; }
  body { margin: 0; width: 768px; height: 512px; background: #f2f6fb; color: #16324f; }
  header { height: 76px; padding: 18px 28px; display: flex; align-items: center;
           justify-content: space-between; background: #123c5a; color: #fff; }
  .brand { font-weight: 700; letter-spacing: .04em; }
  .tag { padding: 7px 12px; border-radius: 16px; background: #35c3a5; color: #08382f; font-size: 12px; }
  main { padding: 26px 30px; display: grid; grid-template-columns: 1.2fr .8fr; gap: 22px; }
  h1 { margin: 0 0 10px; font-size: 30px; line-height: 1.1; }
  p { margin: 0; font-size: 15px; line-height: 1.45; color: #4e6982; }
  .card { background: #fff; border: 1px solid #d8e4ef; border-radius: 14px; padding: 20px; box-shadow: 0 8px 20px #0c375e12; }
  .metric { margin-top: 20px; display: flex; gap: 12px; }
  .metric span { display: block; font-size: 24px; font-weight: 700; color: #123c5a; }
  .metric small { color: #7190a6; }
  .chart { height: 214px; padding: 16px; display: flex; align-items: end; gap: 10px; }
  .bar { flex: 1; border-radius: 7px 7px 3px 3px; background: linear-gradient(#35c3a5, #1f8e93); }
  .bar:nth-child(1) { height: 38%; } .bar:nth-child(2) { height: 63%; }
  .bar:nth-child(3) { height: 52%; } .bar:nth-child(4) { height: 88%; }
  .bar:nth-child(5) { height: 76%; } .bar:nth-child(6) { height: 96%; }
  footer { position: absolute; left: 30px; bottom: 18px; font-size: 11px; color: #7b96aa; }
</style></head><body>
  <header><div class=\"brand\">FIELD NOTES / IMAGE LAB</div><div class=\"tag\">LOCAL PREVIEW</div></header>
  <main><section><h1>Small images,<br>clear signals.</h1><p>A static browser-rendered page used as a compact screenshot fixture. All content is inline and synthetic.</p>
    <div class=\"metric\"><div><span>24.8k</span><small>pixels sampled</small></div><div><span>6</span><small>scenes reviewed</small></div></div></section>
    <section class=\"card chart\"><div class=\"bar\"></div><div class=\"bar\"></div><div class=\"bar\"></div><div class=\"bar\"></div><div class=\"bar\"></div><div class=\"bar\"></div></section></main>
  <footer>Rendered locally by Playwright · synthetic page content</footer>
</body></html>
"""


CASE_INFO: list[dict[str, Any]] = [
    {
        "name": "portrait_astronaut_512",
        "kind": "local_image",
        "source_file": "astronaut.png",
        "source_artifact": "portrait_astronaut_512.source.png",
        "source": {
            "provider": "scikit-image 0.22.0 data asset",
            "primary_source": "https://scikit-image.org/docs/stable/api/skimage.data.html#skimage.data.astronaut",
            "license": "Public domain; no known copyright restrictions (NASA image)",
            "credit": "NASA / Eileen Collins; distributed through scikit-image data",
        },
        "size": (512, 512),
        "transform": "Loaded the exact bundled 512x512 RGB PNG; no resize or crop.",
        "subsampling": "4:2:0",
    },
    {
        "name": "food_coffee_600x400",
        "kind": "local_image",
        "source_file": "coffee.png",
        "source_artifact": "food_coffee_600x400.source.png",
        "source": {
            "provider": "scikit-image 0.22.0 data asset",
            "primary_source": "https://scikit-image.org/docs/stable/api/skimage.data.html#skimage.data.coffee",
            "license": "CC0; no copyright restrictions",
            "credit": "Rachel Michetti / Pikolo Espresso Bar; distributed through scikit-image data",
        },
        "size": (600, 400),
        "transform": "Loaded the exact bundled 600x400 RGB PNG; no resize or crop.",
        "subsampling": "4:2:0",
    },
    {
        "name": "landscape_sunset_640x480",
        "kind": "external_image",
        "source_artifact": "landscape_sunset_640x480.source.JPG",
        "source": {
            "provider": "Wikimedia Commons original upload",
            "primary_source": LANDSCAPE_PAGE,
            "download_url": LANDSCAPE_URL,
            "license": "Public domain; copyright holder released the work worldwide",
            "credit": "Michae2109, Landscape picture.JPG (sunset in Oslo, Norway)",
        },
        "source_expected_sha256": "fd589149cddb338e271619656eaf3833b992c8ce3df8f94eb05ef3ebfc1e0fa4",
        "size": (640, 480),
        "transform": "Decoded the retained 1632x1224 JPEG and resized to 640x480 with Pillow LANCZOS; no crop.",
        "subsampling": "4:2:0",
    },
    {
        "name": "street_vendor_640x480",
        "kind": "external_image",
        "source_file": "street_vendor_640x480.source.jpeg",
        "source_artifact": "street_vendor_640x480.source.jpeg",
        "source": {
            "provider": "Wikimedia Commons original upload",
            "primary_source": STREET_PAGE,
            "download_url": STREET_URL,
            "license": "CC0 1.0 Universal Public Domain Dedication",
            "credit": "Kumar Mangal Roy, Street photography.jpeg (street vendor in Kolkata)",
        },
        "source_expected_sha256": "f479817a2163a193ae96b688e837d54b6717ecbb23824f149292040a0a0b4267",
        "size": (640, 480),
        "transform": "Decoded the retained 4160x3120 JPEG and resized to 640x480 with Pillow LANCZOS; no crop.",
        "subsampling": "4:2:0",
    },
    {
        "name": "transparent_window_icon_512",
        "kind": "svg_icon",
        "source_artifact": "transparent_window_icon_512.source.svg",
        "size": (512, 512),
        "source": {
            "provider": "MoonAV1 fixture author",
            "primary_source": "inline source retained in transparent_window_icon_512.source.svg",
            "license": "CC0 1.0 Universal Public Domain Dedication",
            "credit": "Original simple SVG fixture artwork; no third-party pixels",
        },
        "transform": "Rendered the retained SVG with Playwright Chromium to a 512x512 RGBA PNG with transparent background, then exported the PNG as AVIF.",
        "subsampling": "4:4:4",
        "alpha": True,
    },
    {
        "name": "webpage_dashboard_768x512",
        "kind": "webpage",
        "source_artifact": "webpage_dashboard_768x512.source.html",
        "size": (768, 512),
        "source": {
            "provider": "MoonAV1 fixture author",
            "primary_source": "inline source retained in webpage_dashboard_768x512.source.html",
            "license": "CC0 1.0 Universal Public Domain Dedication",
            "credit": "Original static HTML/CSS page; all content is synthetic",
            "content_type": "synthetic page content, not a photograph",
        },
        "transform": "Rendered the retained HTML/CSS with Playwright Chromium at a 768x512 viewport and exported the screenshot as AVIF.",
        "subsampling": "4:2:0",
    },
    {
        "name": "wide_gamut_adobe_600x400",
        "kind": "local_image_icc",
        "source_file": "astronaut.png",
        "source_artifact": "wide_gamut_adobe_600x400.input.srgb.png",
        "converted_source_artifact": "wide_gamut_adobe_600x400.source.png",
        "input_icc_artifact": "wide_gamut_adobe_600x400.input.srgb.icc",
        "size": (600, 400),
        "source": {
            "provider": "scikit-image 0.22.0 data asset",
            "primary_source": "https://scikit-image.org/docs/stable/api/skimage.data.html#skimage.data.astronaut",
            "license": "Public domain; no known copyright restrictions (NASA image)",
            "credit": "NASA / Eileen Collins; distributed through scikit-image data",
        },
        "source_expected_sha256": "88431cd9653ccd539741b555fb0a46b61558b301d4110412b5bc28b5e3ea6cb5",
        "input_icc_expected_sha256": "2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e",
        "transform": "Loaded the retained 512x512 sRGB astronaut PNG, converted RGB pixels with LittleCMS to AdobeCompat-v2 using rendering intent 0 and flags 0, then resized to 600x400 with Pillow LANCZOS before AVIF export.",
        "subsampling": "4:4:4",
        "icc_artifact": "wide_gamut_adobe_600x400.AdobeCompat-v2.icc",
        "icc": {
            "profile": "AdobeCompat-v2.icc",
            "url": PROFILE_URL,
            "repository": PROFILE_REPO,
            "license": "CC0 1.0 (repository LICENSE)",
            "color_space": "Adobe RGB (1998) compatible RGB wide-gamut profile",
        },
        "icc_expected_sha256": "60fb2adecacf82132db0b1c09b303316f3bbd9e2823e7ba096d01627d12d57c9",
    },
]
BROWSER_VERSIONS: set[str] = set()


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def plane_shapes(width: int, height: int, sampling: str) -> list[tuple[int, int]]:
    if sampling == "400":
        return [(width, height)]
    sub_x = sampling != "444"
    sub_y = sampling == "420"
    return [
        (width, height),
        ((width + int(sub_x)) >> int(sub_x), (height + int(sub_y)) >> int(sub_y)),
        ((width + int(sub_x)) >> int(sub_x), (height + int(sub_y)) >> int(sub_y)),
    ]


def extract_native(lib: Any, data: bytes) -> tuple[bytes, bytes | None, dict[str, int], bytes]:
    decoder = lib.avifDecoderCreate()
    if not decoder:
        raise RuntimeError("libavif decoder allocation failed")
    buffer = C.create_string_buffer(data)
    try:
        for result, stage in (
            (lib.avifDecoderSetSource(decoder, 1), "set item source"),
            (lib.avifDecoderSetIOMemory(decoder, buffer, len(data)), "set memory"),
            (lib.avifDecoderParse(decoder), "parse AVIF"),
            (lib.avifDecoderNextImage(decoder), "decode AVIF"),
        ):
            animation.checked(result, stage)
        state = animation.Decoder.from_address(decoder)
        image = FullImage.from_address(state.image)
        if image.format == 4:
            sampling = "400"
        elif image.format == 1:
            sampling = "444"
        elif image.format == 2:
            sampling = "422"
        elif image.format == 3:
            sampling = "420"
        else:
            raise RuntimeError(f"unexpected libavif yuv format {image.format}")
        size = 1 if image.depth == 8 else 2
        planes = []
        for plane, (width, height) in enumerate(plane_shapes(image.width, image.height, sampling)):
            planes.append(b"".join(
                C.string_at(image.planes[plane] + row * image.strides[plane], width * size)
                for row in range(height)
            ))
        alpha = None
        if image.alpha:
            alpha = b"".join(
                C.string_at(image.alpha + row * image.alpha_stride, image.width * size)
                for row in range(image.height)
            )
        icc = b""
        if image.icc.data and image.icc.size:
            icc = C.string_at(image.icc.data, image.icc.size)
        metadata = {
            "width": int(image.width),
            "height": int(image.height),
            "depth": int(image.depth),
            "format": int(image.format),
            "color_primaries": int(image.primaries),
            "transfer_characteristics": int(image.transfer),
            "matrix_coefficients": int(image.matrix),
            "color_range": int(image.range),
            "premultiplied": int(image.premultiplied),
        }
        return b"".join(planes), alpha, metadata, icc
    finally:
        lib.avifDecoderDestroy(decoder)


def safe_write(path: Path, data: bytes) -> None:
    if path.exists():
        raise RuntimeError(f"refusing to replace existing fixture: {path.name}")
    path.write_bytes(data)


def copy_source(path: Path, destination: Path) -> None:
    if destination.exists():
        if destination.read_bytes() != path.read_bytes():
            raise RuntimeError(f"existing source differs: {destination}")
        return
    shutil.copyfile(path, destination)


def source_asset(info: dict[str, Any], destination: Path) -> Path:
    name = info["name"]
    if info["kind"] in {"local_image", "local_image_icc"}:
        import skimage.data

        source = Path(skimage.data.data_dir) / info["source_file"]
        if not source.is_file():
            raise RuntimeError(f"required local scikit-image source is not installed: {source}")
        copy_source(source, destination / info["source_artifact"])
        retained = destination / info["source_artifact"]
        expected = info.get("source_expected_sha256")
        if expected and sha(retained.read_bytes()) != expected:
            raise RuntimeError(f"retained local source hash differs from pinned source: {retained}")
        return retained
    if info["kind"] == "external_image":
        source = destination / info["source_artifact"]
        if not source.is_file():
            raise RuntimeError(f"retain the licensed source at {source}; download URL: {info['source'].get('download_url')}")
        expected = info.get("source_expected_sha256")
        if expected and sha(source.read_bytes()) != expected:
            raise RuntimeError(f"retained street source hash differs from pinned source: {source}")
        return source
    if info["kind"] == "svg_icon":
        path = destination / info["source_artifact"]
        safe_write(path, SVG_SOURCE.encode("utf-8"))
        return path
    if info["kind"] == "webpage":
        path = destination / info["source_artifact"]
        safe_write(path, WEBPAGE_SOURCE.encode("utf-8"))
        return path
    raise RuntimeError(f"unknown source kind for {name}")


def prepare_image(info: dict[str, Any], source: Path, destination: Path) -> tuple[Any, dict[str, str]]:
    from PIL import Image, ImageCms

    artifacts: dict[str, str] = {source.name: sha(source.read_bytes())}
    target_width, target_height = info["size"]
    if info["kind"] == "local_image_icc":
        original = Image.open(source)
        source_icc = original.info.get("icc_profile")
        if not source_icc:
            raise RuntimeError(f"sRGB source has no embedded ICC profile: {source}")
        input_icc_path = destination / info["input_icc_artifact"]
        safe_write(input_icc_path, source_icc)
        artifacts[input_icc_path.name] = sha(source_icc)
        expected_input_icc = info.get("input_icc_expected_sha256")
        if expected_input_icc and sha(source_icc) != expected_input_icc:
            raise RuntimeError(f"source ICC hash differs from pinned sRGB profile: {source}")
        profile_path = destination / info["icc_artifact"]
        if not profile_path.is_file():
            retained_profile = OUT / info["icc_artifact"]
            if not retained_profile.is_file():
                raise RuntimeError(f"retain the licensed ICC profile at {profile_path}; download URL: {PROFILE_URL}")
            shutil.copyfile(retained_profile, profile_path)
        target_icc = profile_path.read_bytes()
        source_profile = ImageCms.ImageCmsProfile(io.BytesIO(source_icc))
        target_profile = ImageCms.ImageCmsProfile(io.BytesIO(target_icc))
        transform = ImageCms.buildTransform(
            source_profile, target_profile, "RGB", "RGB", renderingIntent=0, flags=0
        )
        image = ImageCms.applyTransform(original.convert("RGB"), transform)
        image = image.resize(info["size"], Image.Resampling.LANCZOS)
        converted_path = destination / info["converted_source_artifact"]
        image.save(converted_path, format="PNG", icc_profile=target_icc, compress_level=9)
        artifacts[converted_path.name] = sha(converted_path.read_bytes())
        artifacts[profile_path.name] = sha(target_icc)
        return image, artifacts
    if info["kind"] in {"local_image", "external_image"}:
        image = Image.open(source).convert("RGB")
        if image.size != info["size"]:
            image = image.resize(info["size"], Image.Resampling.LANCZOS)
    elif info["kind"] == "svg_icon":
        from playwright.sync_api import sync_playwright

        png_path = destination / f"{info['name']}.source.png"
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            BROWSER_VERSIONS.add(browser.version)
            page = browser.new_page(viewport={"width": target_width, "height": target_height}, device_scale_factor=1)
            page.set_content(source.read_text(encoding="utf-8"), wait_until="load")
            page.screenshot(path=str(png_path), omit_background=True)
            browser.close()
        artifacts[png_path.name] = sha(png_path.read_bytes())
        image = Image.open(png_path).convert("RGBA")
    elif info["kind"] == "webpage":
        from playwright.sync_api import sync_playwright

        png_path = destination / f"{info['name']}.source.png"
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            BROWSER_VERSIONS.add(browser.version)
            page = browser.new_page(viewport={"width": target_width, "height": target_height}, device_scale_factor=1)
            page.set_content(source.read_text(encoding="utf-8"), wait_until="load")
            page.screenshot(path=str(png_path), animations="disabled")
            browser.close()
        artifacts[png_path.name] = sha(png_path.read_bytes())
        image = Image.open(png_path).convert("RGB")
    else:
        raise RuntimeError(f"unknown image kind: {info['kind']}")
    if image.size != info["size"]:
        raise RuntimeError(f"unexpected source dimensions for {info['name']}: {image.size}")
    return image, artifacts


def build_case(info: dict[str, Any], lib: Any, destination: Path) -> dict[str, Any]:
    source = source_asset(info, destination)
    image, artifacts = prepare_image(info, source, destination)
    avif_path = destination / f"{info['name']}.avif"
    save_kwargs: dict[str, Any] = {
        "format": "AVIF",
        "quality": 75,
        "speed": 6,
        "subsampling": info["subsampling"],
        "range": "full",
        "max_threads": 16,
        "autotiling": True,
    }
    if info.get("alpha"):
        save_kwargs["alpha_premultiplied"] = False
    if info.get("icc_artifact"):
        icc_path = destination / info["icc_artifact"]
        if not icc_path.is_file():
            raise RuntimeError(f"retain the licensed ICC profile at {icc_path}; download URL: {PROFILE_URL}")
        icc = icc_path.read_bytes()
        expected_icc = info.get("icc_expected_sha256")
        if expected_icc and sha(icc) != expected_icc:
            raise RuntimeError(f"retained ICC profile hash differs from pinned source: {icc_path}")
        save_kwargs["icc_profile"] = icc
        artifacts[icc_path.name] = sha(icc)
    image.save(avif_path, **save_kwargs)
    artifacts[avif_path.name] = sha(avif_path.read_bytes())
    native, alpha, metadata, embedded_icc = extract_native(lib, avif_path.read_bytes())
    sampling = {1: "444", 2: "422", 3: "420", 4: "400"}.get(metadata["format"])
    if sampling is None:
        raise RuntimeError(f"unknown output sampling for {info['name']}")
    expected_sampling = {"4:4:4": "444", "4:2:2": "422", "4:2:0": "420"}[info["subsampling"]]
    if sampling != expected_sampling:
        raise RuntimeError(f"requested {expected_sampling} but libavif produced {sampling} for {info['name']}")
    metadata["sampling"] = sampling
    metadata["icc_sha256"] = sha(embedded_icc) if embedded_icc else None
    if info.get("icc_artifact") and embedded_icc != (destination / info["icc_artifact"]).read_bytes():
        raise RuntimeError(f"libavif did not preserve embedded ICC bytes for {info['name']}")
    reference_path = destination / f"{info['name']}.reference.yuv"
    safe_write(reference_path, native)
    artifacts[reference_path.name] = sha(native)
    has_alpha = alpha is not None
    if bool(info.get("alpha")) != has_alpha:
        raise RuntimeError(f"alpha expectation differs for {info['name']}")
    if alpha is not None:
        alpha_path = destination / f"{info['name']}.alpha.yuv"
        safe_write(alpha_path, alpha)
        artifacts[alpha_path.name] = sha(alpha)
    image.close()
    case: dict[str, Any] = {
        "name": info["name"],
        "width": metadata["width"],
        "height": metadata["height"],
        "depth": metadata["depth"],
        "sampling": sampling,
        "frames": 1,
        "sequence_metadata": {
            key: metadata[key]
            for key in ("color_primaries", "transfer_characteristics", "matrix_coefficients", "color_range")
        },
        "alpha": has_alpha,
        "alpha_full_range": bool(has_alpha),
        "premultiplied": bool(metadata["premultiplied"]),
        "modes": ["avif"],
        "source": info["source"],
        "source_sha256": artifacts[source.name],
        "transform": info["transform"],
        "export_command": [
            "Pillow.Image.save",
            "format=AVIF",
            "quality=75",
            "speed=6",
            f"subsampling={info['subsampling']}",
            "range=full",
            "max_threads=16",
            "autotiling=true",
        ],
        "artifacts": artifacts,
        "libavif_metadata": metadata,
    }
    if info.get("icc"):
        case["icc"] = {**info["icc"], "artifact": info["icc_artifact"], "sha256": sha((destination / info["icc_artifact"]).read_bytes())}
    if info.get("converted_source_artifact"):
        case["converted_source_sha256"] = artifacts[info["converted_source_artifact"]]
        case["input_icc_sha256"] = artifacts[info["input_icc_artifact"]]
        case["color_conversion"] = {
            "engine": "LittleCMS",
            "version": "2.19",
            "source_profile_artifact": info["input_icc_artifact"],
            "target_profile_artifact": info["icc_artifact"],
            "rendering_intent": 0,
            "flags": 0,
            "pixel_format": "RGB -> RGB",
            "resize": "Pillow LANCZOS 512x512 -> 600x400 after profile conversion",
        }
    if info["kind"] == "svg_icon":
        case["render_command"] = [
            "Playwright Chromium headless",
            "viewport=512x512",
            "device_scale_factor=1",
            "page.screenshot(omit_background=true)",
        ]
        case["export_command"].append("alpha_premultiplied=false")
    elif info["kind"] == "webpage":
        case["render_command"] = [
            "Playwright Chromium headless",
            "viewport=768x512",
            "device_scale_factor=1",
            "page.screenshot(animations=disabled)",
        ]
    if info.get("icc_artifact"):
        case["export_command"].append(f"icc_profile={info['icc_artifact']}")
    elif embedded_icc:
        case["export_command"].append("icc_profile=source-embedded")
    return case


def verify_case(case: dict[str, Any], destination: Path) -> None:
    for name, digest in case["artifacts"].items():
        path = destination / name
        if not path.is_file():
            raise RuntimeError(f"missing artifact for {case['name']}: {name}")
        actual = sha(path.read_bytes())
        if actual != digest:
            raise RuntimeError(f"artifact hash mismatch for {case['name']}: {name}")
    info = next(info for info in CASE_INFO if info['name'] == case['name'])
    if case.get('source_sha256') != case['artifacts'].get(info['source_artifact']):
        raise RuntimeError(f"source hash differs from its named artifact for {case['name']}")
    avif = destination / f"{case['name']}.avif"
    from PIL import Image

    with Image.open(avif) as image:
        if image.size != (case["width"], case["height"]):
            raise RuntimeError(f"Pillow dimensions differ for {case['name']}")
    sample_bytes = 1 if case["depth"] == 8 else 2
    native_size = sum(width * height for width, height in plane_shapes(case["width"], case["height"], case["sampling"])) * sample_bytes
    if (destination / f"{case['name']}.reference.yuv").stat().st_size != native_size:
        raise RuntimeError(f"native reference extent differs for {case['name']}")
    alpha_path = destination / f"{case['name']}.alpha.yuv"
    if case["alpha"]:
        if not alpha_path.is_file() or alpha_path.stat().st_size != case["width"] * case["height"] * sample_bytes:
            raise RuntimeError(f"alpha reference extent differs for {case['name']}")
    elif alpha_path.exists():
        raise RuntimeError(f"unexpected alpha reference for opaque case {case['name']}")


def redecode_case(case: dict[str, Any], lib: Any, destination: Path) -> None:
    native, alpha, metadata, embedded_icc = extract_native(lib, (destination / f"{case['name']}.avif").read_bytes())
    if native != (destination / f"{case['name']}.reference.yuv").read_bytes():
        raise RuntimeError(f"libavif native reference differs for {case['name']}")
    expected_alpha = (destination / f"{case['name']}.alpha.yuv").read_bytes() if case["alpha"] else None
    if alpha != expected_alpha:
        raise RuntimeError(f"libavif alpha reference differs for {case['name']}")
    for key, value in case["libavif_metadata"].items():
        if key == "icc_sha256":
            if value != (sha(embedded_icc) if embedded_icc else None):
                raise RuntimeError(f"libavif ICC metadata differs for {case['name']}")
        elif key == "sampling":
            continue
        elif metadata.get(key) != value:
            raise RuntimeError(f"libavif metadata differs for {case['name']}: {key}")


def check_manifest(args: argparse.Namespace) -> None:
    manifest_path = OUT / "manifest.json"
    if not manifest_path.is_file():
        raise SystemExit(f"missing corpus manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    cases = manifest.get("cases")
    if not isinstance(cases, list) or len(cases) != len(CASE_INFO):
        raise RuntimeError("manifest case count differs from the bounded real-image corpus")
    names = [case.get("name") for case in cases]
    if names != [info["name"] for info in CASE_INFO]:
        raise RuntimeError("manifest case order or names differ from generator contract")
    for case in cases:
        info = next(info for info in CASE_INFO if info["name"] == case["name"])
        if case['source'] != info['source'] or case['transform'] != info['transform']:
            raise RuntimeError(f"source attribution or transformation differs: {case['name']}")
        if info.get('icc_artifact') and (
                case.get('icc',{}).get('artifact') != info['icc_artifact'] or
                case.get('icc',{}).get('sha256') != case['artifacts'][info['icc_artifact']]):
            raise RuntimeError(f"ICC record differs from named profile artifact: {case['name']}")
        expected_sampling = {"4:4:4": "444", "4:2:2": "422", "4:2:0": "420"}[info["subsampling"]]
        expected_alpha = bool(info.get("alpha", False))
        if (case.get("width"), case.get("height"), case.get("depth"), case.get("sampling"), case.get("alpha")) != (
            info["size"][0], info["size"][1], 8, expected_sampling, expected_alpha
        ):
            raise RuntimeError(f"manifest dimensions/sampling/alpha differ from generator contract: {case['name']}")
        if case.get("alpha_full_range") != expected_alpha or case.get("premultiplied") is not False:
            raise RuntimeError(f"manifest alpha/range/premultiplication differs from generator contract: {case['name']}")
        if case.get("modes") != ["avif"] or case.get("frames") != 1:
            raise RuntimeError(f"invalid file-consumer mode/frame contract for {case['name']}")
        export = case.get("export_command", [])
        if "max_threads=16" not in export or "autotiling=true" not in export:
            raise RuntimeError(f"missing deterministic Pillow encoder options: {case['name']}")
        if expected_alpha and "alpha_premultiplied=false" not in export:
            raise RuntimeError(f"missing explicit alpha encoder option: {case['name']}")
        if info.get("icc_artifact") and not any(item == f"icc_profile={info['icc_artifact']}" for item in export):
            raise RuntimeError(f"missing explicit ICC encoder option: {case['name']}")
        if case.get("libavif_metadata", {}).get("icc_sha256") and not info.get("icc_artifact") and "icc_profile=source-embedded" not in export:
            raise RuntimeError(f"missing explicit source ICC encoder option: {case['name']}")
        if info["kind"] in {"svg_icon", "webpage"} and not case.get("render_command"):
            raise RuntimeError(f"missing explicit browser rendering command: {case['name']}")
        metadata = case.get("libavif_metadata", {})
        if (metadata.get("width"), metadata.get("height"), metadata.get("depth"), metadata.get("sampling")) != (
            case["width"], case["height"], case["depth"], case["sampling"]
        ):
            raise RuntimeError(f"libavif dimensions/depth/sampling differ from case metadata: {case['name']}")
        for key in ("color_primaries", "transfer_characteristics", "matrix_coefficients", "color_range"):
            if metadata.get(key) != case["sequence_metadata"].get(key):
                raise RuntimeError(f"sequence metadata differs from libavif metadata for {case['name']}: {key}")
        verify_case(case, OUT)
    if args.redecode:
        lib_path = Path(args.libavif)
        if not lib_path.is_file():
            raise SystemExit(f"libavif library not found: {lib_path}")
        lib, version = animation.library(str(lib_path))
        expected_version = manifest.get("tool_versions", {}).get("libavif")
        if version != expected_version:
            raise RuntimeError(f"libavif version differs: {version} != {expected_version}")
        for case in cases:
            redecode_case(case, lib, OUT)
    print(f"Real AVIF corpus checked: {len(cases)} cases; no files changed.")


def generate(args: argparse.Namespace) -> None:
    manifest_path = OUT / "manifest.json"
    if manifest_path.exists():
        raise SystemExit(f"saved corpus exists; use --check or --redecode: {manifest_path}")
    lib_path = Path(args.libavif)
    if not lib_path.is_file():
        raise SystemExit(f"libavif library not found: {lib_path}")
    if OUT.exists():
        allowed_sources = {
            "street_vendor_640x480.source.jpeg",
            "landscape_sunset_640x480.source.JPG",
            "wide_gamut_adobe_600x400.AdobeCompat-v2.icc",
        }
        unexpected = [path.name for path in OUT.iterdir() if path.name not in allowed_sources]
        if unexpected:
            raise SystemExit(f"refusing to replace existing partial corpus: {OUT} ({', '.join(sorted(unexpected))})")
    OUT.mkdir(parents=True, exist_ok=True)
    lib, libavif_version = animation.library(str(lib_path))
    try:
        import PIL
        import playwright
        from PIL import _avif
        from PIL import AvifImagePlugin

        pillow_version = PIL.__version__
        playwright_version = importlib.metadata.version("playwright")
        pillow_codec = AvifImagePlugin.get_codec_version("aom") or "unknown"
        pillow_decoder = AvifImagePlugin.get_codec_version("dav1d") or "unknown"
        pillow_libavif = _avif.libavif_version
        pillow_codec_versions = _avif.codec_versions()
        from PIL import ImageCms
        littlecms_version = ImageCms.core.littlecms_version
    except Exception as exc:
        raise RuntimeError(f"Pillow AVIF support and Playwright are required: {exc}") from exc
    cases = []
    for info in CASE_INFO:
        print(f"Generating {info['name']}...", flush=True)
        cases.append(build_case(info, lib, OUT))
    manifest = {
        "schema": "file-consumer-v1",
        "scope": "bounded real application-exported AVIF images: portrait, food/product, landscape, street, transparent illustration/icon, browser-rendered webpage, and one ICC-tagged wide-gamut RGB case",
        "generator": "scripts/generate-real-image-reference.py",
        "tool_versions": {
            "python": sys.version.split()[0],
            "Pillow": pillow_version,
            "scikit-image": importlib.metadata.version("scikit-image"),
            "Pillow_linked_libavif": pillow_libavif,
            "Pillow_AVIF_encoder": pillow_codec,
            "Pillow_AVIF_decoder": pillow_decoder,
            "Pillow_AVIF_codec_versions": pillow_codec_versions,
            "LittleCMS": littlecms_version,
            "Playwright": playwright_version,
            "Chromium": ", ".join(sorted(BROWSER_VERSIONS)),
            "libavif": libavif_version,
        },
        "libavif_path": str(lib_path),
        "cases": cases,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Generated real AVIF corpus: {len(cases)} cases in {OUT}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify hashes and extents without writing")
    parser.add_argument("--redecode", action="store_true", help="also decode each AVIF with libavif and compare native planes")
    parser.add_argument("--libavif", default=str(DEFAULT_LIBAVIF), help="pinned libavif 0.11.1 library")
    args = parser.parse_args()
    if args.redecode and not args.check:
        args.check = True
    if args.check:
        check_manifest(args)
    else:
        generate(args)


if __name__ == "__main__":
    main()
