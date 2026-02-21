#!/usr/bin/env bash
# 03_setup_s3.sh - Create S3 bucket and upload CRAM data
#
# Creates:
#   s3://<YOUR_BUCKET_NAME>/
#   ├── reference/GRCh38/          - Reference genome
#   ├── internal/cram/             - CRAM master data (internal_id)
#   └── metadata/eid_mapping/      - Per-project EID mapping JSON

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/data"

# --- Configuration ---
# Set your S3 bucket name below (default: genomics-poc-<YOUR_ACCOUNT_ID>)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "<YOUR_ACCOUNT_ID>")
BUCKET_NAME="${BUCKET_NAME:-genomics-poc-${ACCOUNT_ID}}"
REGION="ap-northeast-2"

echo "=== S3 Bucket Setup ==="
echo "Bucket: s3://$BUCKET_NAME"
echo "Region: $REGION"
echo "Account: $ACCOUNT_ID"
echo ""

# --- Step 1: Create bucket ---
echo "[Step 1] Creating S3 bucket..."
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    echo "  Bucket already exists: $BUCKET_NAME"
else
    aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION"
    echo "  Created bucket: $BUCKET_NAME"
fi
echo ""

# --- Step 2: Enable versioning (data protection) ---
echo "[Step 2] Enabling versioning..."
aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled
echo "  Versioning enabled"
echo ""

# --- Step 3: Upload reference genome ---
echo "[Step 3] Uploading reference genome..."
REF_DIR="$DATA_DIR/reference"
if [ -d "$REF_DIR" ] && [ "$(ls -A "$REF_DIR" 2>/dev/null)" ]; then
    aws s3 sync "$REF_DIR/" "s3://$BUCKET_NAME/reference/GRCh38/" \
        --no-progress
    echo "  Uploaded reference files:"
    aws s3 ls "s3://$BUCKET_NAME/reference/GRCh38/" | sed 's/^/    /'
else
    echo "  WARNING: No reference files found in $REF_DIR"
    echo "  Run 02_generate_cram.sh first"
fi
echo ""

# --- Step 4: Upload CRAM files ---
echo "[Step 4] Uploading CRAM files..."
SAMPLES_DIR="$DATA_DIR/samples"
if [ -d "$SAMPLES_DIR" ] && [ "$(ls -A "$SAMPLES_DIR" 2>/dev/null)" ]; then
    aws s3 sync "$SAMPLES_DIR/" "s3://$BUCKET_NAME/internal/cram/" \
        --no-progress \
        --content-type "application/octet-stream"
    echo "  Uploaded CRAM files:"
    aws s3 ls "s3://$BUCKET_NAME/internal/cram/" | sed 's/^/    /'
else
    echo "  WARNING: No CRAM files found in $SAMPLES_DIR"
    echo "  Run 02_generate_cram.sh first"
fi
echo ""

# --- Step 5: Upload EID mapping ---
echo "[Step 5] Uploading EID mapping..."
MAPPING_DIR="$DATA_DIR/mapping"
if [ -d "$MAPPING_DIR" ] && [ "$(ls -A "$MAPPING_DIR" 2>/dev/null)" ]; then
    aws s3 sync "$MAPPING_DIR/" "s3://$BUCKET_NAME/metadata/eid_mapping/" \
        --no-progress \
        --content-type "application/json"
    echo "  Uploaded mapping files:"
    aws s3 ls "s3://$BUCKET_NAME/metadata/eid_mapping/" | sed 's/^/    /'
else
    echo "  WARNING: No mapping files found in $MAPPING_DIR"
fi
echo ""

# --- Step 6: Verify upload ---
echo "[Step 6] Verification..."
echo ""
echo "S3 bucket contents:"
aws s3 ls "s3://$BUCKET_NAME/" --recursive --human-readable | head -30
echo ""

# Verify CRAM files are accessible
echo "CRAM file check:"
FIRST_CRAM="s3://$BUCKET_NAME/internal/cram/internal_id_000001.cram"
if aws s3api head-object --bucket "$BUCKET_NAME" --key "internal/cram/internal_id_000001.cram" &>/dev/null; then
    SIZE=$(aws s3api head-object --bucket "$BUCKET_NAME" --key "internal/cram/internal_id_000001.cram" --query ContentLength --output text)
    echo "  internal_id_000001.cram: $SIZE bytes - OK"
else
    echo "  internal_id_000001.cram: NOT FOUND"
fi

echo ""
echo "=== S3 setup complete ==="
echo ""
echo "Bucket: s3://$BUCKET_NAME"
echo "CRAM prefix: s3://$BUCKET_NAME/internal/cram/"
echo "Reference prefix: s3://$BUCKET_NAME/reference/GRCh38/"
echo "Mapping prefix: s3://$BUCKET_NAME/metadata/eid_mapping/"
