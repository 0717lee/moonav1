#!/usr/bin/env python3
"""Restore versioned optional media fixtures without changing tracked metadata."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import urllib.request
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        while chunk := source.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def crc32(path):
    value = 0
    with path.open('rb') as source:
        while chunk := source.read(8 * 1024 * 1024):
            value = zlib.crc32(chunk, value)
    return value & 0xffffffff


def metadata(path):
    return path.suffix in ('.md', '.json') or 'license' in path.name.lower() or path.name == 'copyright.txt'


def checked_archive(group, record, index, cache, archive_dir):
    name = group + '.zip'
    archive = (archive_dir or cache) / name
    if archive.is_file() and sha256(archive) == record['archive_sha256']:
        return archive
    parts = []
    for part in record['parts']:
        if Path(part['name']).name != part['name']:
            raise ValueError('Invalid fixture asset name')
        path = (archive_dir or cache) / part['name']
        valid = path.is_file() and path.stat().st_size == part['bytes'] and sha256(path) == part['sha256']
        if not valid:
            if archive_dir:
                raise ValueError(f'Missing or changed local asset: {path}')
            url = f"https://github.com/{index['repository']}/releases/download/{index['release']}/{part['name']}"
            temporary = path.with_name(path.name + '.download')
            print('Downloading', part['name'], flush=True)
            request = urllib.request.Request(url, headers={'User-Agent': 'MoonAV1-fixtures'})
            with urllib.request.urlopen(request, timeout=90) as source, temporary.open('wb') as output:
                shutil.copyfileobj(source, output, 8 * 1024 * 1024)
            if temporary.stat().st_size != part['bytes'] or sha256(temporary) != part['sha256']:
                raise ValueError(f'Fixture download verification failed: {temporary}')
            temporary.replace(path)
        parts.append(path)
    if len(parts) == 1:
        archive = parts[0]
    else:
        archive = cache / name
        temporary = archive.with_name(archive.name + '.assembling')
        with temporary.open('wb') as output:
            for part in parts:
                with part.open('rb') as source:
                    shutil.copyfileobj(source, output, 8 * 1024 * 1024)
        if sha256(temporary) != record['archive_sha256']:
            raise ValueError('Assembled fixture archive differs')
        temporary.replace(archive)
        if not archive_dir:
            for part in parts:
                part.unlink()
    if sha256(archive) != record['archive_sha256']:
        raise ValueError(f'Fixture archive differs: {archive}')
    return archive


def restore(archive, group, destination):
    destination.mkdir(parents=True, exist_ok=True)
    destination = destination.resolve()
    count = 0
    with zipfile.ZipFile(archive) as source:
        for member in source.infolist():
            path = Path(member.filename)
            target = (destination / path).resolve()
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != group:
                raise ValueError(f'Invalid archive path: {member.filename}')
            if not target.is_relative_to(destination) or (member.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError(f'Unsafe archive path: {member.filename}')
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if target.exists():
                # Repository documentation and manifests remain authoritative.
                if metadata(target):
                    continue
                if target.stat().st_size != member.file_size or crc32(target) != member.CRC:
                    raise ValueError(f'Existing fixture differs; remove it before restoring: {target}')
                count += 1
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
                    temporary = Path(output.name)
                    with source.open(member) as input_file:
                        shutil.copyfileobj(input_file, output, 8 * 1024 * 1024)
                temporary.replace(target)
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
            count += 1
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('groups', nargs='*', help='Group names, or all')
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--root', type=Path, default=ROOT / 'tests/fixtures')
    parser.add_argument('--cache', type=Path, default=ROOT / '_build/fixture-downloads')
    parser.add_argument('--archive-dir', type=Path, help='Use already downloaded assets without network access')
    args = parser.parse_args()
    index = json.loads((ROOT / 'tests/fixtures/downloads.json').read_text(encoding='utf8'))
    if args.list:
        for name, record in index['groups'].items():
            print(f"{name}: {record['uncompressed_bytes'] / 1024**2:.1f} MiB unpacked")
        return
    groups = list(index['groups']) if args.groups == ['all'] else args.groups
    if not groups or len(set(groups)) != len(groups) or any(g not in index['groups'] for g in groups):
        parser.error('Choose distinct groups from --list, or all')
    args.cache.mkdir(parents=True, exist_ok=True)
    for group in groups:
        archive = checked_archive(group, index['groups'][group], index, args.cache, args.archive_dir)
        count = restore(archive, group, args.root)
        print(f'{group}: {count} fixture files restored or verified', flush=True)


if __name__ == '__main__':
    main()
