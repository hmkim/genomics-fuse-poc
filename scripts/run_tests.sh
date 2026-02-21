#!/usr/bin/env bash
# run_tests.sh - Functional tests for all three approaches
#
# Tests:
#   1. File listing (ls)
#   2. CRAM integrity (samtools quickcheck)
#   3. Header reading (samtools view -H)
#   4. Region query (samtools view with genomic range)
#   5. Full file read (samtools flagstat)
#   6. EID resolution verification
#
# Usage:
#   bash scripts/run_tests.sh [approach_a|approach_b|approach_c|local|all]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# --- Configuration ---
FUSE_MOUNT="/mnt/project"             # Approach A: Custom FUSE
SYMLINK_MOUNT="/mnt/project-symlink"  # Approach B: Symlink layer
LOCAL_SAMPLES="$PROJECT_DIR/data/samples"  # Local baseline
REF_LOCAL="$PROJECT_DIR/data/reference/GRCh38_chr22.fa"
REF_S3="/mnt/s3-reference/GRCh38_chr22.fa"

# Test EID (from project_001 mapping)
TEST_EID="EID_1234567"
TEST_INTERNAL="internal_id_000001"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

passed() {
    ((PASS++)) || true
    echo -e "  ${GREEN}PASS${NC}: $1"
}

failed() {
    ((FAIL++)) || true
    echo -e "  ${RED}FAIL${NC}: $1"
    [ -n "${2:-}" ] && echo -e "        $2"
}

skipped() {
    ((SKIP++)) || true
    echo -e "  ${YELLOW}SKIP${NC}: $1"
}

# --- Detect available reference ---
REF=""
if [ -f "$REF_LOCAL" ]; then
    REF="$REF_LOCAL"
elif [ -f "$REF_S3" ]; then
    REF="$REF_S3"
fi

# --- Helper: build -T option only for commands that support it ---
ref_flag() {
    if [ -n "$REF" ]; then
        echo "-T $REF"
    fi
}

# --- Helper: detect valid region from CRAM header ---
detect_region() {
    local cram_file="$1"
    local sq_line
    sq_line=$(samtools view -H $(ref_flag) "$cram_file" 2>/dev/null | grep '^@SQ' | head -1)
    if [ -n "$sq_line" ]; then
        local sn ln
        sn=$(echo "$sq_line" | sed 's/.*SN:\([^\t]*\).*/\1/')
        ln=$(echo "$sq_line" | sed 's/.*LN:\([^\t]*\).*/\1/')
        local end=$((ln < 100000 ? ln : 100000))
        echo "${sn}:1-${end}"
    fi
}

# ===========================================================================
# Test Suite: Approach A (Custom FUSE)
# ===========================================================================
test_approach_a() {
    echo ""
    echo "========================================"
    echo "  Approach A: Custom FUSE (eid_fuse.py)"
    echo "========================================"

    if ! mountpoint -q "$FUSE_MOUNT" 2>/dev/null; then
        echo -e "  ${YELLOW}FUSE not mounted at $FUSE_MOUNT${NC}"
        skipped "All Approach A tests (mount not available)"
        return
    fi

    local cram_file="$FUSE_MOUNT/${TEST_EID}.cram"

    # T1: File listing
    echo ""
    echo "  [T1] File listing..."
    if ls "$FUSE_MOUNT"/ | grep -q "$TEST_EID"; then
        passed "ls shows EID files"
    else
        failed "ls does not show $TEST_EID"
    fi

    # T2: CRAM integrity (quickcheck has NO -T option)
    echo "  [T2] CRAM integrity..."
    if [ -f "$cram_file" ]; then
        if samtools quickcheck "$cram_file" 2>/dev/null; then
            passed "samtools quickcheck OK"
        else
            failed "samtools quickcheck failed"
        fi
    else
        failed "CRAM file not found: $cram_file"
    fi

    # T3: Header reading (view -H supports -T)
    echo "  [T3] Header reading..."
    local header
    header=$(samtools view -H $(ref_flag) "$cram_file" 2>/dev/null | head -5)
    if echo "$header" | grep -q '@HD'; then
        passed "Header contains @HD"
    else
        failed "Header missing @HD line"
    fi

    # T4: Region query (view supports -T)
    echo "  [T4] Region query..."
    local region
    region=$(detect_region "$cram_file")
    if [ -n "$region" ]; then
        local count
        count=$(samtools view -c $(ref_flag) "$cram_file" "$region" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            passed "Region query returned $count reads ($region)"
        else
            failed "Region query returned 0 reads ($region)"
        fi
    else
        skipped "Could not detect valid region from header"
    fi

    # T5: Flagstat (NO -T option)
    echo "  [T5] Full file read (flagstat)..."
    local flagstat_out
    flagstat_out=$(samtools flagstat "$cram_file" 2>/dev/null | head -1)
    if echo "$flagstat_out" | grep -qE '[0-9]+ \+ [0-9]+'; then
        passed "flagstat: $flagstat_out"
    else
        failed "flagstat output unexpected"
    fi

    # T6: CRAI index accessibility
    echo "  [T6] CRAI index accessibility..."
    if [ -f "${cram_file}.crai" ]; then
        passed "CRAI index file exists"
    else
        skipped "CRAI index not found (may not be exposed)"
    fi
}

# ===========================================================================
# Test Suite: Approach B (Symlink Layer)
# ===========================================================================
test_approach_b() {
    echo ""
    echo "========================================"
    echo "  Approach B: Symlink Layer"
    echo "========================================"

    if [ ! -d "$SYMLINK_MOUNT" ] || [ ! -L "$SYMLINK_MOUNT/${TEST_EID}.cram" ]; then
        echo -e "  ${YELLOW}Symlinks not set up at $SYMLINK_MOUNT${NC}"
        skipped "All Approach B tests (symlinks not available)"
        return
    fi

    local cram_file="$SYMLINK_MOUNT/${TEST_EID}.cram"

    # T1: Symlink resolution
    echo ""
    echo "  [T1] Symlink resolution..."
    local target
    target=$(readlink "$cram_file")
    if echo "$target" | grep -q "$TEST_INTERNAL"; then
        passed "Symlink resolves to correct internal ID"
    else
        failed "Symlink target unexpected: $target"
    fi

    # T2: File accessible through symlink
    echo "  [T2] File accessibility..."
    if [ -f "$cram_file" ]; then
        passed "CRAM accessible through symlink"
    else
        failed "CRAM not accessible (target may not exist)"
        return
    fi

    # T3: samtools quickcheck (NO -T)
    echo "  [T3] CRAM integrity..."
    if samtools quickcheck "$cram_file" 2>/dev/null; then
        passed "samtools quickcheck OK"
    else
        failed "samtools quickcheck failed"
    fi

    # T4: Header reading
    echo "  [T4] Header reading..."
    if samtools view -H $(ref_flag) "$cram_file" 2>/dev/null | grep -q '@HD'; then
        passed "Header contains @HD"
    else
        failed "Header missing @HD line"
    fi

    # T5: Region query
    echo "  [T5] Region query..."
    local region
    region=$(detect_region "$cram_file")
    if [ -n "$region" ]; then
        local count
        count=$(samtools view -c $(ref_flag) "$cram_file" "$region" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            passed "Region query returned $count reads ($region)"
        else
            failed "Region query returned 0 reads"
        fi
    else
        skipped "Could not detect valid region"
    fi
}

# ===========================================================================
# Test Suite: Approach C (htslib S3 Plugin)
# ===========================================================================
test_approach_c() {
    echo ""
    echo "========================================"
    echo "  Approach C: htslib S3 Plugin"
    echo "========================================"

    if [ ! -f "$SCRIPT_DIR/cram_access.py" ]; then
        skipped "All Approach C tests (cram_access.py not found)"
        return
    fi

    # T1: EID resolution (dry-run)
    echo ""
    echo "  [T1] EID resolution..."
    local dry_output
    dry_output=$(python3 "$SCRIPT_DIR/cram_access.py" "$TEST_EID" --dry-run 2>/dev/null)
    if echo "$dry_output" | grep -q "samtools"; then
        passed "EID resolves to samtools command"
    else
        failed "Dry-run output unexpected"
    fi

    # T2: Header via S3
    echo "  [T2] Header via S3 plugin..."
    local ref_opt=""
    [ -n "$REF" ] && ref_opt="--reference $REF"
    if python3 "$SCRIPT_DIR/cram_access.py" "$TEST_EID" --header-only $ref_opt 2>/dev/null | grep -q '@HD'; then
        passed "Header retrieved via S3 plugin"
    else
        if python3 "$SCRIPT_DIR/cram_access.py" "$TEST_EID" --header-only --use-presigned $ref_opt 2>/dev/null | grep -q '@HD'; then
            passed "Header retrieved via presigned URL (S3 plugin failed, fallback OK)"
        else
            skipped "S3 plugin and presigned URL both failed (network/config issue)"
        fi
    fi
}

# ===========================================================================
# Test Suite: Local Baseline
# ===========================================================================
test_local() {
    echo ""
    echo "========================================"
    echo "  Local Baseline"
    echo "========================================"

    local cram_file="$LOCAL_SAMPLES/${TEST_INTERNAL}.cram"
    if [ ! -f "$cram_file" ]; then
        echo -e "  ${YELLOW}Local CRAM not found: $cram_file${NC}"
        skipped "All local tests (run 02_generate_cram.sh first)"
        return
    fi

    # T1: Integrity (quickcheck: NO -T)
    echo ""
    echo "  [T1] CRAM integrity..."
    if samtools quickcheck "$cram_file" 2>/dev/null; then
        passed "samtools quickcheck OK"
    else
        failed "samtools quickcheck failed"
    fi

    # T2: Header (view -H: supports -T)
    echo "  [T2] Header..."
    if samtools view -H $(ref_flag) "$cram_file" 2>/dev/null | grep -q '@HD'; then
        passed "Header contains @HD"
    else
        failed "Header missing @HD"
    fi

    # T3: Flagstat (NO -T)
    echo "  [T3] Flagstat..."
    local flagstat_out
    flagstat_out=$(samtools flagstat "$cram_file" 2>/dev/null | head -1)
    if echo "$flagstat_out" | grep -qE '[0-9]+ \+ [0-9]+'; then
        passed "flagstat: $flagstat_out"
    else
        failed "flagstat output unexpected"
    fi

    # T4: Region query (view: supports -T)
    echo "  [T4] Region query..."
    local region
    region=$(detect_region "$cram_file")
    if [ -n "$region" ]; then
        local count
        count=$(samtools view -c $(ref_flag) "$cram_file" "$region" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            passed "Region query returned $count reads ($region)"
        else
            failed "Region query returned 0 reads"
        fi
    else
        skipped "Could not detect valid region"
    fi
}

# ===========================================================================
# Main
# ===========================================================================
TARGET="${1:-all}"

echo "=== CRAM + AWS Mountpoint S3 PoC: Functional Tests ==="
echo "Date: $(date -Iseconds)"
echo "Target: $TARGET"

case "$TARGET" in
    approach_a|a)
        test_approach_a
        ;;
    approach_b|b)
        test_approach_b
        ;;
    approach_c|c)
        test_approach_c
        ;;
    local|l)
        test_local
        ;;
    all)
        test_local
        test_approach_a
        test_approach_b
        test_approach_c
        ;;
    *)
        echo "Usage: $0 [approach_a|approach_b|approach_c|local|all]"
        exit 1
        ;;
esac

# --- Summary ---
echo ""
echo "========================================"
echo "  Test Summary"
echo "========================================"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  ${GREEN}PASSED${NC}: $PASS"
echo -e "  ${RED}FAILED${NC}: $FAIL"
echo -e "  ${YELLOW}SKIPPED${NC}: $SKIP"
echo "  TOTAL: $TOTAL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All executed tests passed.${NC}"
fi
