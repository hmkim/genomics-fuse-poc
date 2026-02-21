#!/usr/bin/env python3
from __future__ import annotations

"""
verify_byte_range.py - Byte-range read consistency verification

Verifies that identical byte ranges return identical data across all access
methods (Custom FUSE, Symlink/Mountpoint S3, S3 direct, local file).

This is critical for CRAM correctness: samtools relies on exact byte-range
reads for CRAM slice decoding, and any inconsistency would cause silent
data corruption.

Tests:
  1. Fixed offsets: beginning, middle, end of file
  2. CRAM-relevant offsets: header, EOF marker, random slices
  3. Cross-method MD5 comparison

Usage:
    python3 scripts/verify_byte_range.py [--all] [--verbose]
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import struct

import boto3
from botocore.config import Config as BotoConfig


def md5(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def read_local(filepath: str, offset: int, size: int) -> bytes | None:
    """Read bytes from a local file."""
    try:
        with open(filepath, 'rb') as f:
            f.seek(offset)
            return f.read(size)
    except (OSError, IOError) as e:
        print(f"  [local] Error reading {filepath}: {e}", file=sys.stderr)
        return None


def read_fuse(filepath: str, offset: int, size: int) -> bytes | None:
    """Read bytes through FUSE mount (same as local read, different path)."""
    return read_local(filepath, offset, size)


def read_s3_direct(s3_client, bucket: str, key: str,
                   offset: int, size: int) -> bytes | None:
    """Read bytes directly from S3 using Range header."""
    try:
        resp = s3_client.get_object(
            Bucket=bucket,
            Key=key,
            Range=f"bytes={offset}-{offset + size - 1}"
        )
        return resp['Body'].read()
    except Exception as e:
        print(f"  [s3] Error reading s3://{bucket}/{key}: {e}", file=sys.stderr)
        return None


class ByteRangeVerifier:
    """Verify byte-range consistency across access methods."""

    def __init__(self, config: dict):
        self.config = config
        self.s3 = boto3.client(
            's3',
            region_name=config.get('region', 'ap-northeast-2'),
            config=BotoConfig(signature_version='s3v4')
        )
        self.results = []
        self.verbose = config.get('verbose', False)

    def verify_range(self, offset: int, size: int, label: str = "") -> dict:
        """
        Read the same byte range from all available sources and compare MD5.
        """
        result = {
            'label': label,
            'offset': offset,
            'size': size,
            'sources': {},
            'match': False,
            'error': None,
        }

        hashes = {}

        # --- Source 1: Local file ---
        local_path = self.config.get('local_path')
        if local_path and os.path.isfile(local_path):
            data = read_local(local_path, offset, size)
            if data is not None:
                h = md5(data)
                result['sources']['local'] = {
                    'md5': h, 'bytes_read': len(data)
                }
                hashes['local'] = h

        # --- Source 2: FUSE mount ---
        fuse_path = self.config.get('fuse_path')
        if fuse_path and os.path.isfile(fuse_path):
            data = read_fuse(fuse_path, offset, size)
            if data is not None:
                h = md5(data)
                result['sources']['fuse'] = {
                    'md5': h, 'bytes_read': len(data)
                }
                hashes['fuse'] = h

        # --- Source 3: Symlink mount ---
        symlink_path = self.config.get('symlink_path')
        if symlink_path and os.path.isfile(symlink_path):
            data = read_local(symlink_path, offset, size)
            if data is not None:
                h = md5(data)
                result['sources']['symlink'] = {
                    'md5': h, 'bytes_read': len(data)
                }
                hashes['symlink'] = h

        # --- Source 4: S3 direct ---
        bucket = self.config.get('bucket')
        s3_key = self.config.get('s3_key')
        if bucket and s3_key:
            data = read_s3_direct(self.s3, bucket, s3_key, offset, size)
            if data is not None:
                h = md5(data)
                result['sources']['s3_direct'] = {
                    'md5': h, 'bytes_read': len(data)
                }
                hashes['s3_direct'] = h

        # --- Compare ---
        if len(hashes) < 2:
            result['error'] = f"Only {len(hashes)} source(s) available, need >= 2"
        else:
            unique_hashes = set(hashes.values())
            result['match'] = len(unique_hashes) == 1
            if not result['match']:
                result['error'] = f"Hash mismatch: {hashes}"

        self.results.append(result)
        return result

    def get_file_size(self) -> int:
        """Get file size from first available source."""
        local_path = self.config.get('local_path')
        if local_path and os.path.isfile(local_path):
            return os.path.getsize(local_path)

        bucket = self.config.get('bucket')
        s3_key = self.config.get('s3_key')
        if bucket and s3_key:
            try:
                resp = self.s3.head_object(Bucket=bucket, Key=s3_key)
                return resp['ContentLength']
            except Exception:
                pass

        fuse_path = self.config.get('fuse_path')
        if fuse_path and os.path.isfile(fuse_path):
            return os.path.getsize(fuse_path)

        return 0

    def run_standard_tests(self) -> list[dict]:
        """Run a standard set of byte-range verification tests."""
        file_size = self.get_file_size()
        if file_size == 0:
            print("ERROR: Could not determine file size", file=sys.stderr)
            return []

        print(f"File size: {file_size} bytes")
        print(f"Sources: {self._available_sources()}")
        print()

        tests = []

        # --- Test 1: CRAM magic bytes (first 4 bytes) ---
        tests.append(('CRAM magic (first 26 bytes)', 0, 26))

        # --- Test 2: First 4KB (CRAM file definition + header) ---
        tests.append(('First 4KB (header region)', 0, 4096))

        # --- Test 3: Middle of file ---
        mid = file_size // 2
        tests.append((f'Middle 4KB (offset={mid})', mid, min(4096, file_size - mid)))

        # --- Test 4: Last 4KB (CRAM EOF container) ---
        end_offset = max(0, file_size - 4096)
        tests.append((f'Last 4KB (offset={end_offset})', end_offset, min(4096, file_size)))

        # --- Test 5: CRAM EOF marker (last 38 bytes) ---
        eof_offset = max(0, file_size - 38)
        tests.append((f'CRAM EOF marker (last 38 bytes)', eof_offset, min(38, file_size)))

        # --- Test 6: Large range (1MB from offset 0) ---
        large_size = min(1024 * 1024, file_size)
        tests.append(('First 1MB', 0, large_size))

        # --- Test 7: Random offsets ---
        import random
        random.seed(42)
        for i in range(3):
            rand_offset = random.randint(0, max(0, file_size - 8192))
            rand_size = min(8192, file_size - rand_offset)
            tests.append((f'Random range #{i+1} (offset={rand_offset})',
                          rand_offset, rand_size))

        # Run all tests
        print(f"Running {len(tests)} byte-range verification tests...")
        print()

        for label, offset, size in tests:
            result = self.verify_range(offset, size, label)
            status = "PASS" if result['match'] else "FAIL"
            if result['error'] and not result['match']:
                status = "FAIL"
            elif result['error']:
                status = "WARN"

            sources_str = ', '.join(
                f"{k}={v['md5'][:8]}" for k, v in result['sources'].items()
            )
            print(f"  [{status}] {label}")
            print(f"         offset={offset}, size={size}")
            print(f"         {sources_str}")
            if result['error']:
                print(f"         ERROR: {result['error']}")
            print()

        return self.results

    def _available_sources(self) -> list[str]:
        sources = []
        if self.config.get('local_path') and os.path.isfile(self.config['local_path']):
            sources.append('local')
        if self.config.get('fuse_path') and os.path.isfile(self.config['fuse_path']):
            sources.append('fuse')
        if self.config.get('symlink_path') and os.path.isfile(self.config['symlink_path']):
            sources.append('symlink')
        if self.config.get('bucket') and self.config.get('s3_key'):
            sources.append('s3_direct')
        return sources

    def summary(self) -> dict:
        total = len(self.results)
        passed = sum(1 for r in self.results if r['match'])
        failed = sum(1 for r in self.results if not r['match'] and not r['error'])
        errored = sum(1 for r in self.results
                      if r['error'] and not r['match'])
        return {
            'total': total,
            'passed': passed,
            'failed': failed,
            'errored': errored,
            'all_match': passed == total,
        }


def main():
    parser = argparse.ArgumentParser(
        description='Verify byte-range read consistency across access methods'
    )

    parser.add_argument('--eid', default='EID_1234567',
                        help='EID to test (default: EID_1234567)')
    parser.add_argument('--internal-id', default='internal_id_000001',
                        help='Internal ID (default: internal_id_000001)')
    parser.add_argument('--project', default='project_001',
                        help='Project ID')
    parser.add_argument('--bucket', default=None,
                        help='S3 bucket')
    parser.add_argument('--region', default='ap-northeast-2',
                        help='AWS region')
    parser.add_argument('--fuse-mount', default='/mnt/project',
                        help='FUSE mount point')
    parser.add_argument('--symlink-mount', default='/mnt/project-symlink',
                        help='Symlink mount point')
    parser.add_argument('--verbose', '-v', action='store_true')
    parser.add_argument('--json', action='store_true',
                        help='Output results as JSON')

    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)

    # Auto-detect bucket
    if args.bucket is None:
        try:
            account_id = boto3.client('sts').get_caller_identity()['Account']
            args.bucket = f'genomics-poc-{account_id}'
        except Exception:
            args.bucket = '<YOUR_BUCKET_NAME>'

    config = {
        'region': args.region,
        'bucket': args.bucket,
        's3_key': f'internal/cram/{args.internal_id}.cram',
        'local_path': os.path.join(project_dir, 'data', 'samples',
                                   f'{args.internal_id}.cram'),
        'fuse_path': os.path.join(args.fuse_mount, f'{args.eid}.cram'),
        'symlink_path': os.path.join(args.symlink_mount, f'{args.eid}.cram'),
        'verbose': args.verbose,
    }

    print("=== Byte-Range Read Consistency Verification ===")
    print(f"EID: {args.eid} -> {args.internal_id}")
    print(f"Bucket: {args.bucket}")
    print()

    verifier = ByteRangeVerifier(config)
    results = verifier.run_standard_tests()

    summary = verifier.summary()

    print("=== Summary ===")
    print(f"Total tests: {summary['total']}")
    print(f"Passed:      {summary['passed']}")
    print(f"Failed:      {summary['failed']}")
    print(f"Errored:     {summary['errored']}")
    print()

    if summary['all_match']:
        print("ALL BYTE RANGES MATCH across available sources.")
    else:
        print("WARNING: Some byte ranges did NOT match!")

    if args.json:
        print()
        print(json.dumps({
            'summary': summary,
            'results': results,
        }, indent=2, default=str))

    sys.exit(0 if summary['all_match'] else 1)


if __name__ == '__main__':
    main()
