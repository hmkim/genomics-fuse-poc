#!/usr/bin/env bash
# 01_install_tools.sh - Install all required tools for CRAM + AWS Mountpoint S3 PoC
#
# Usage: sudo bash scripts/01_install_tools.sh
#
# Installs:
#   - samtools + htslib (CRAM processing)
#   - AWS Mountpoint for Amazon S3
#   - fusepy (Python FUSE bindings for custom FUSE)
#   - wgsim (synthetic read generation, bundled with samtools)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== CRAM + AWS Mountpoint S3 PoC: Tool Installation ==="
echo "Project directory: $PROJECT_DIR"
echo ""

# --- 1. samtools + htslib ---
echo "[1/4] Installing samtools and htslib..."
if command -v samtools &>/dev/null; then
    echo "  samtools already installed: $(samtools --version | head -1)"
else
    # Try Amazon Linux 2023 package manager first
    if command -v dnf &>/dev/null; then
        sudo dnf install -y samtools || {
            echo "  dnf install failed, trying yum..."
            sudo yum install -y samtools
        }
    elif command -v yum &>/dev/null; then
        sudo yum install -y samtools
    else
        echo "  ERROR: Neither dnf nor yum found. Install samtools manually."
        echo "  See: https://www.htslib.org/download/"
        exit 1
    fi
fi

# Install htslib-devel for htslib S3 plugin support
echo "  Installing htslib development headers..."
if command -v dnf &>/dev/null; then
    sudo dnf install -y htslib htslib-devel 2>/dev/null || \
        sudo yum install -y htslib htslib-devel 2>/dev/null || \
        echo "  WARNING: htslib-devel not available in repos, S3 plugin may not work"
elif command -v yum &>/dev/null; then
    sudo yum install -y htslib htslib-devel 2>/dev/null || \
        echo "  WARNING: htslib-devel not available in repos, S3 plugin may not work"
fi

echo "  samtools version: $(samtools --version | head -1)"
echo ""

# --- 2. AWS Mountpoint for Amazon S3 ---
echo "[2/4] Installing AWS Mountpoint for Amazon S3..."
if command -v mount-s3 &>/dev/null; then
    echo "  mount-s3 already installed: $(mount-s3 --version 2>&1 || echo 'version unknown')"
else
    MOUNT_S3_RPM="/tmp/mount-s3.rpm"
    echo "  Downloading mount-s3 RPM..."
    wget -q -O "$MOUNT_S3_RPM" \
        "https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.rpm"
    echo "  Installing mount-s3..."
    sudo yum install -y "$MOUNT_S3_RPM"
    rm -f "$MOUNT_S3_RPM"
    echo "  mount-s3 version: $(mount-s3 --version 2>&1 || echo 'installed')"
fi
echo ""

# --- 3. Python FUSE bindings (fusepy) ---
echo "[3/4] Installing Python FUSE bindings (fusepy)..."
if python3 -c "import fuse" 2>/dev/null; then
    echo "  fusepy already installed"
else
    pip3 install fusepy --quiet
    echo "  fusepy installed"
fi

# Verify FUSE device exists
if [ -c /dev/fuse ]; then
    echo "  /dev/fuse: OK"
else
    echo "  WARNING: /dev/fuse not found. FUSE may not work."
    echo "  Try: sudo modprobe fuse"
fi

# Install fuse-libs if not present
if ! rpm -q fuse-libs &>/dev/null 2>&1; then
    echo "  Installing fuse-libs..."
    sudo yum install -y fuse fuse-libs 2>/dev/null || true
fi
echo ""

# --- 4. Additional bioinformatics tools ---
echo "[4/4] Checking additional tools..."

# wgsim is typically bundled with samtools or available separately
if command -v wgsim &>/dev/null; then
    echo "  wgsim: available"
else
    echo "  wgsim: not found (will use samtools for synthetic data generation)"
    # Try to install from misc/wgsim in samtools source, or use alternative approach
    # For PoC, we'll generate synthetic data using samtools directly
fi

# Check for minimap2 (optional, for alignment)
if command -v minimap2 &>/dev/null; then
    echo "  minimap2: available"
else
    echo "  minimap2: not found (will use bwa or samtools for alignment)"
fi

# Check for bwa (alternative aligner)
if command -v bwa &>/dev/null; then
    echo "  bwa: available"
else
    echo "  bwa: not found"
    echo "  Installing bwa..."
    sudo yum install -y bwa 2>/dev/null || \
        sudo dnf install -y bwa 2>/dev/null || \
        echo "  WARNING: bwa not available, synthetic CRAM generation may need adjustment"
fi
echo ""

# --- Verification Summary ---
echo "=== Installation Summary ==="
echo "samtools:  $(command -v samtools 2>/dev/null && samtools --version | head -1 || echo 'NOT INSTALLED')"
echo "mount-s3:  $(command -v mount-s3 2>/dev/null && mount-s3 --version 2>&1 || echo 'NOT INSTALLED')"
echo "fusepy:    $(python3 -c 'import fuse; print("installed")' 2>/dev/null || echo 'NOT INSTALLED')"
echo "aws cli:   $(aws --version 2>/dev/null || echo 'NOT INSTALLED')"
echo "python3:   $(python3 --version 2>/dev/null || echo 'NOT INSTALLED')"
echo ""
echo "FUSE device: $([ -c /dev/fuse ] && echo 'OK (/dev/fuse exists)' || echo 'MISSING')"
echo ""
echo "=== Installation complete ==="
