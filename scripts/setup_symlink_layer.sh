#!/usr/bin/env bash
# setup_symlink_layer.sh - Approach B: Symlink-based EID mapping layer
#
# Creates a directory of EID-named symlinks pointing to Mountpoint S3 paths.
# Simple alternative to Custom FUSE that provides EID -> internal_id mapping
# without metadata caching or prefetch.
#
# Usage:
#   bash scripts/setup_symlink_layer.sh [project_id] [mount_point]
#
# Example:
#   bash scripts/setup_symlink_layer.sh project_001 /mnt/project-symlink
#
# Prerequisites:
#   - Mountpoint S3 mounted at /mnt/s3-internal (04_mount_s3.sh)
#   - EID mapping file at data/mapping/eid_mapping.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MAPPING_FILE="$PROJECT_DIR/data/mapping/eid_mapping.json"

PROJECT_ID="${1:-project_001}"
MOUNT_POINT="${2:-/mnt/project-symlink}"
S3_INTERNAL="${3:-/mnt/s3-internal}"

echo "=== Approach B: Symlink Layer Setup ==="
echo "Project ID: $PROJECT_ID"
echo "Mount point: $MOUNT_POINT"
echo "S3 backend: $S3_INTERNAL"
echo "Mapping file: $MAPPING_FILE"
echo ""

# --- Validation ---
if [ ! -f "$MAPPING_FILE" ]; then
    echo "ERROR: Mapping file not found: $MAPPING_FILE"
    exit 1
fi

# Check if S3 is mounted (warn but don't fail - might be testing locally)
if [ -d "$S3_INTERNAL" ]; then
    if mountpoint -q "$S3_INTERNAL" 2>/dev/null; then
        echo "S3 backend: MOUNTED"
    else
        echo "WARNING: $S3_INTERNAL exists but is not a mount point"
        echo "  Symlinks will be created but may not resolve until S3 is mounted"
    fi
else
    echo "WARNING: $S3_INTERNAL does not exist"
    echo "  Creating directory for local testing..."
    sudo mkdir -p "$S3_INTERNAL"
fi

# --- Create symlink directory ---
echo ""
echo "[Step 1] Creating symlink directory: $MOUNT_POINT"
sudo mkdir -p "$MOUNT_POINT"

# --- Parse mapping and create symlinks ---
echo "[Step 2] Creating EID -> internal_id symlinks..."

# Extract mappings for the specified project using Python
python3 -c "
import json
import os
import sys

with open('$MAPPING_FILE') as f:
    mapping = json.load(f)

project_id = '$PROJECT_ID'
if project_id not in mapping:
    print(f'ERROR: Project {project_id} not found in mapping file')
    print(f'Available projects: {list(mapping.keys())}')
    sys.exit(1)

project_mapping = mapping[project_id]
mount_point = '$MOUNT_POINT'
s3_internal = '$S3_INTERNAL'
count = 0

for eid, internal_id in project_mapping.items():
    # Create symlink: /mnt/project-symlink/EID_XXXXXXX.cram -> /mnt/s3-internal/internal_id_XXXXXX.cram
    for ext in ['.cram', '.cram.crai']:
        link_path = os.path.join(mount_point, f'{eid}{ext}')
        target_path = os.path.join(s3_internal, f'{internal_id}{ext}')

        # Remove existing symlink
        if os.path.islink(link_path):
            os.unlink(link_path)

        os.symlink(target_path, link_path)
        count += 1

print(f'Created {count} symlinks for project {project_id} ({len(project_mapping)} samples)')
" || {
    echo "ERROR: Failed to create symlinks"
    exit 1
}

echo ""

# --- Verify ---
echo "[Step 3] Verification..."
echo ""
echo "Symlink directory contents:"
ls -la "$MOUNT_POINT"/ 2>/dev/null | head -20

echo ""
echo "Symlink targets:"
for link in "$MOUNT_POINT"/*.cram; do
    if [ -L "$link" ]; then
        target=$(readlink "$link")
        name=$(basename "$link")
        exists="NO"
        [ -f "$target" ] && exists="YES"
        printf "  %-25s -> %-50s [exists: %s]\n" "$name" "$target" "$exists"
    fi
done 2>/dev/null || echo "  No .cram symlinks found"

echo ""
echo "=== Symlink layer setup complete ==="
echo ""
echo "Usage:"
echo "  samtools view -H $MOUNT_POINT/EID_1234567.cram"
echo "  samtools view -T /mnt/s3-reference/GRCh38_chr22.fa $MOUNT_POINT/EID_1234567.cram chr22:16000000-16100000"
echo ""
echo "To remove:"
echo "  sudo rm -rf $MOUNT_POINT"
