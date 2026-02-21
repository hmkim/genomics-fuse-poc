#!/usr/bin/env python3
"""
cram_access.py - Approach C: htslib S3 Plugin Direct Access Wrapper

Translates EID to S3 URL and invokes samtools directly, bypassing FUSE entirely.
Uses htslib's built-in S3 plugin for byte-range access.

This approach has zero FUSE memory overhead but lacks the filesystem abstraction
that allows tools to transparently access EID-named files.

Usage:
    python3 scripts/cram_access.py <eid> [region] [--project PROJECT] [--reference REF]

Examples:
    python3 scripts/cram_access.py EID_1234567
    python3 scripts/cram_access.py EID_1234567 chr22:16000000-16100000
    python3 scripts/cram_access.py EID_1234567 chr22:16M-17M --project project_001
    python3 scripts/cram_access.py EID_1234567 --command flagstat
"""

import argparse
import json
import os
import subprocess
import sys
import time

import boto3
from botocore.config import Config as BotoConfig


def load_mapping(mapping_file, project_id):
    """Load EID -> internal_id mapping for a project."""
    with open(mapping_file) as f:
        mapping = json.load(f)

    if project_id not in mapping:
        print(f"ERROR: Project '{project_id}' not found in mapping file", file=sys.stderr)
        print(f"Available projects: {list(mapping.keys())}", file=sys.stderr)
        sys.exit(1)

    return mapping[project_id]


def resolve_eid(mapping, eid):
    """Resolve EID to internal_id."""
    if eid not in mapping:
        print(f"ERROR: EID '{eid}' not found in project mapping", file=sys.stderr)
        print(f"Available EIDs: {list(mapping.keys())}", file=sys.stderr)
        sys.exit(1)

    return mapping[eid]


def get_s3_url(bucket, internal_id, region):
    """Generate S3 URL for htslib access."""
    # htslib S3 URL format: s3://bucket/key
    s3_key = f"internal/cram/{internal_id}.cram"
    return f"s3://{bucket}/{s3_key}"


def get_presigned_url(bucket, internal_id, region, expiry=3600):
    """Generate presigned URL as fallback for htslib S3 access."""
    s3_key = f"internal/cram/{internal_id}.cram"
    s3_client = boto3.client('s3', region_name=region,
                             config=BotoConfig(signature_version='s3v4'))
    url = s3_client.generate_presigned_url(
        'get_object',
        Params={'Bucket': bucket, 'Key': s3_key},
        ExpiresIn=expiry
    )
    return url


def run_samtools_s3(s3_url, region, reference, genomic_region=None, command="view"):
    """Run samtools with htslib S3 plugin."""
    # Set htslib S3 environment variables
    env = os.environ.copy()
    env['HTS_S3_REGION'] = region
    # Use AWS credential chain (IAM role, env vars, etc.)
    env['HTS_S3_ADDRESS'] = f's3.{region}.amazonaws.com'

    # Build samtools command
    cmd = ['samtools', command]

    if command == 'view':
        if reference:
            cmd.extend(['-T', reference])
        cmd.append(s3_url)
        if genomic_region:
            # For region queries, we need the index too
            cmd.append(genomic_region)
    elif command == 'flagstat':
        cmd.append(s3_url)
    elif command == 'quickcheck':
        cmd.append(s3_url)
    elif command == 'idxstats':
        cmd.append(s3_url)
    else:
        cmd.append(s3_url)

    return cmd, env


def run_samtools_presigned(presigned_url, reference, genomic_region=None, command="view"):
    """Run samtools with presigned URL (fallback)."""
    cmd = ['samtools', command]

    if command == 'view':
        if reference:
            cmd.extend(['-T', reference])
        cmd.append(presigned_url)
        if genomic_region:
            cmd.append(genomic_region)
    else:
        cmd.append(presigned_url)

    return cmd, os.environ.copy()


def main():
    parser = argparse.ArgumentParser(
        description='Approach C: Direct S3 CRAM access via htslib S3 plugin',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s EID_1234567                          # View all reads
  %(prog)s EID_1234567 chr22:16000000-16100000  # Region query
  %(prog)s EID_1234567 --command flagstat       # Flagstat
  %(prog)s EID_1234567 --command quickcheck     # Integrity check
  %(prog)s EID_1234567 --header-only            # Header only
        """
    )

    parser.add_argument('eid', help='EID identifier (e.g., EID_1234567)')
    parser.add_argument('region', nargs='?', default=None,
                        help='Genomic region (e.g., chr22:16000000-16100000)')
    parser.add_argument('--project', default='project_001',
                        help='Project ID (default: project_001)')
    parser.add_argument('--bucket', default=None,
                        help='S3 bucket name (auto-detected from AWS account)')
    parser.add_argument('--aws-region', default='ap-northeast-2',
                        help='AWS region (default: ap-northeast-2)')
    parser.add_argument('--reference', '-T', default=None,
                        help='Reference FASTA path (local or S3)')
    parser.add_argument('--mapping', default=None,
                        help='EID mapping JSON file path')
    parser.add_argument('--command', '-c', default='view',
                        choices=['view', 'flagstat', 'quickcheck', 'idxstats', 'stats'],
                        help='samtools command (default: view)')
    parser.add_argument('--header-only', '-H', action='store_true',
                        help='Show header only (for view command)')
    parser.add_argument('--use-presigned', action='store_true',
                        help='Use presigned URL instead of htslib S3 plugin')
    parser.add_argument('--benchmark', action='store_true',
                        help='Print timing information')
    parser.add_argument('--dry-run', action='store_true',
                        help='Print command without executing')

    args = parser.parse_args()

    # Resolve paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)

    if args.mapping is None:
        args.mapping = os.path.join(project_dir, 'data', 'mapping', 'eid_mapping.json')

    if args.reference is None:
        # Try local reference first, then S3 reference mount
        local_ref = os.path.join(project_dir, 'data', 'reference', 'GRCh38_chr22.fa')
        s3_ref = '/mnt/s3-reference/GRCh38_chr22.fa'
        if os.path.exists(local_ref):
            args.reference = local_ref
        elif os.path.exists(s3_ref):
            args.reference = s3_ref

    if args.bucket is None:
        try:
            account_id = boto3.client('sts').get_caller_identity()['Account']
            args.bucket = f'genomics-poc-{account_id}'
        except Exception:
            args.bucket = '<YOUR_BUCKET_NAME>'

    # Load mapping and resolve EID
    mapping = load_mapping(args.mapping, args.project)
    internal_id = resolve_eid(mapping, args.eid)

    print(f"# EID Resolution: {args.eid} -> {internal_id}", file=sys.stderr)
    print(f"# Bucket: {args.bucket}", file=sys.stderr)
    print(f"# Region: {args.aws_region}", file=sys.stderr)

    # Build S3 URL
    if args.use_presigned:
        url = get_presigned_url(args.bucket, internal_id, args.aws_region)
        print(f"# Access: Presigned URL", file=sys.stderr)
    else:
        url = get_s3_url(args.bucket, internal_id, args.aws_region)
        print(f"# Access: htslib S3 plugin", file=sys.stderr)

    # Build samtools command
    command = args.command
    genomic_region = args.region

    if args.header_only and command == 'view':
        # Insert -H flag for header-only view
        pass  # Handled below

    if args.use_presigned:
        cmd, env = run_samtools_presigned(url, args.reference, genomic_region, command)
    else:
        cmd, env = run_samtools_s3(url, args.aws_region, args.reference, genomic_region, command)

    if args.header_only and command == 'view':
        cmd.insert(2, '-H')

    print(f"# Command: {' '.join(cmd)}", file=sys.stderr)
    print(f"#", file=sys.stderr)

    if args.dry_run:
        print(' '.join(cmd))
        return

    # Execute
    start_time = time.time()
    try:
        result = subprocess.run(cmd, env=env, check=False)
        elapsed = time.time() - start_time

        if args.benchmark:
            print(f"#", file=sys.stderr)
            print(f"# Elapsed: {elapsed:.3f}s", file=sys.stderr)
            print(f"# Exit code: {result.returncode}", file=sys.stderr)

        sys.exit(result.returncode)
    except FileNotFoundError:
        print("ERROR: samtools not found. Install with: sudo yum install -y samtools",
              file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == '__main__':
    main()
