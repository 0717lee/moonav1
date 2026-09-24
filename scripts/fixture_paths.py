"""Resolve historical manifest paths inside this standalone repository.

Manifests retain their original PixelForge paths as provenance. Consumers use
the same repository-relative location in MoonAV1, never the old worktree.
"""

from pathlib import Path, PureWindowsPath

ROOT = Path(__file__).resolve().parents[1]


def fixture_path(recorded: str) -> Path:
    normalized = recorded.replace("\\", "/")
    path = Path(normalized)
    if normalized.startswith("/") or PureWindowsPath(recorded).is_absolute():
        parts = normalized.split("/")
        roots = [index for index, part in enumerate(parts) if part in ("pixelforge", "moonav1")]
        if not roots:
            raise ValueError(f"manifest path has no known repository root: {recorded}")
        path = Path(*parts[roots[-1] + 1:])
    resolved = (ROOT / path).resolve()
    if not resolved.is_relative_to(ROOT):
        raise ValueError(f"manifest path escapes the repository: {recorded}")
    return resolved
