#!/usr/bin/env bash
# 04_mount_s3.sh - Mount S3 bucket using AWS Mountpoint for Amazon S3
#
# Creates two mount points:
#   /mnt/s3-internal   - CRAM master data (internal_id, read-only)
#   /mnt/s3-reference  - Reference genome (read-only)
#
# These mounts serve as the backend for the Custom FUSE layer (eid_fuse.py)
# and are NOT directly exposed to researchers.
#
# Usage:
#   sudo bash scripts/04_mount_s3.sh [mount|unmount|status]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---
# Set your S3 bucket name below (default: genomics-poc-<YOUR_ACCOUNT_ID>)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "<YOUR_ACCOUNT_ID>")
BUCKET_NAME="${BUCKET_NAME:-genomics-poc-${ACCOUNT_ID}}"
REGION="ap-northeast-2"

MOUNT_INTERNAL="/mnt/s3-internal"
MOUNT_REFERENCE="/mnt/s3-reference"
CACHE_DIR="/tmp/mountpoint-cache"
LOG_DIR="/var/log/mount-s3"

ACTION="${1:-mount}"

do_mount() {
    echo "=== Mountpoint S3 Setup ==="
    echo "Bucket: $BUCKET_NAME"
    echo "Region: $REGION"
    echo ""

    # Check mount-s3 is installed
    if ! command -v mount-s3 &>/dev/null; then
        echo "ERROR: mount-s3 not installed. Run 01_install_tools.sh first."
        exit 1
    fi

    # Create mount points and cache directory
    sudo mkdir -p "$MOUNT_INTERNAL" "$MOUNT_REFERENCE" "$CACHE_DIR" "$LOG_DIR"

    # --- Mount 1: Internal CRAM data ---
    echo "[1/2] Mounting internal CRAM data..."
    if mountpoint -q "$MOUNT_INTERNAL" 2>/dev/null; then
        echo "  Already mounted: $MOUNT_INTERNAL"
    else
        mount-s3 "$BUCKET_NAME" "$MOUNT_INTERNAL" \
            --read-only \
            --region "$REGION" \
            --prefix "internal/cram/" \
            --allow-other \
            --log-directory "$LOG_DIR" \
            --cache "$CACHE_DIR/internal" \
            --metadata-ttl 3600 \
            --max-threads 16
        echo "  Mounted: s3://$BUCKET_NAME/internal/cram/ -> $MOUNT_INTERNAL"
    fi

    # --- Mount 2: Reference genome ---
    echo "[2/2] Mounting reference genome..."
    if mountpoint -q "$MOUNT_REFERENCE" 2>/dev/null; then
        echo "  Already mounted: $MOUNT_REFERENCE"
    else
        mount-s3 "$BUCKET_NAME" "$MOUNT_REFERENCE" \
            --read-only \
            --region "$REGION" \
            --prefix "reference/GRCh38/" \
            --allow-other \
            --log-directory "$LOG_DIR" \
            --cache "$CACHE_DIR/reference" \
            --metadata-ttl indefinite \
            --max-threads 8
        echo "  Mounted: s3://$BUCKET_NAME/reference/GRCh38/ -> $MOUNT_REFERENCE"
    fi

    echo ""
    echo "=== Mount Points ==="
    echo "Internal CRAM: $MOUNT_INTERNAL"
    ls -la "$MOUNT_INTERNAL"/ 2>/dev/null | head -10 || echo "  (empty or not ready)"
    echo ""
    echo "Reference: $MOUNT_REFERENCE"
    ls -la "$MOUNT_REFERENCE"/ 2>/dev/null | head -10 || echo "  (empty or not ready)"
    echo ""
    echo "Cache: $CACHE_DIR"
    echo "Logs: $LOG_DIR"
}

do_unmount() {
    echo "=== Unmounting Mountpoint S3 ==="

    if mountpoint -q "$MOUNT_INTERNAL" 2>/dev/null; then
        sudo umount "$MOUNT_INTERNAL"
        echo "  Unmounted: $MOUNT_INTERNAL"
    else
        echo "  Not mounted: $MOUNT_INTERNAL"
    fi

    if mountpoint -q "$MOUNT_REFERENCE" 2>/dev/null; then
        sudo umount "$MOUNT_REFERENCE"
        echo "  Unmounted: $MOUNT_REFERENCE"
    else
        echo "  Not mounted: $MOUNT_REFERENCE"
    fi

    echo ""
    echo "=== Unmount complete ==="
}

do_status() {
    echo "=== Mountpoint S3 Status ==="
    echo ""

    echo "Mount points:"
    for mp in "$MOUNT_INTERNAL" "$MOUNT_REFERENCE"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            echo "  $mp: MOUNTED"
            ls "$mp"/ 2>/dev/null | head -5 | sed 's/^/    /'
        else
            echo "  $mp: NOT MOUNTED"
        fi
    done

    echo ""
    echo "mount-s3 processes:"
    ps aux | grep '[m]ount-s3' || echo "  No mount-s3 processes running"

    echo ""
    echo "Cache usage:"
    du -sh "$CACHE_DIR"/* 2>/dev/null || echo "  No cache data"
}

case "$ACTION" in
    mount)
        do_mount
        ;;
    unmount|umount)
        do_unmount
        ;;
    status)
        do_status
        ;;
    *)
        echo "Usage: $0 [mount|unmount|status]"
        exit 1
        ;;
esac
