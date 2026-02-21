#!/usr/bin/env bash
# benchmark.sh - Performance benchmark for CRAM access approaches
#
# Compares latency and throughput across:
#   - Approach A: Custom FUSE (eid_fuse.py)
#   - Approach B: Symlink + Mountpoint S3
#   - Approach C: htslib S3 Plugin
#   - Local baseline (direct file access)
#
# Tests:
#   1. Header read (metadata access latency)
#   2. Region query (100KB byte-range read)
#   3. Full file flagstat (sequential whole-file read)
#   4. Sequential read throughput (prefetch effect)
#
# Usage:
#   bash scripts/benchmark.sh [--iterations N] [--output FILE]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# --- Configuration ---
ITERATIONS="${ITERATIONS:-3}"
OUTPUT_FILE=""
FUSE_MOUNT="/mnt/project"
SYMLINK_MOUNT="/mnt/project-symlink"
LOCAL_SAMPLES="$PROJECT_DIR/data/samples"
REF_LOCAL="$PROJECT_DIR/data/reference/GRCh38_chr22.fa"
REF_S3="/mnt/s3-reference/GRCh38_chr22.fa"

TEST_EID="EID_1234567"
TEST_INTERNAL="internal_id_000001"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --iterations|-n)
            ITERATIONS="$2"
            shift 2
            ;;
        --output|-o)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--iterations N] [--output FILE]"
            exit 1
            ;;
    esac
done

# Detect reference
REF=""
if [ -f "$REF_LOCAL" ]; then
    REF="$REF_LOCAL"
elif [ -f "$REF_S3" ]; then
    REF="$REF_S3"
fi
REF_OPT=""
[ -n "$REF" ] && REF_OPT="-T $REF"

# Results array
declare -A RESULTS

# --- Timing helper ---
# Returns elapsed time in milliseconds
time_cmd() {
    local start end elapsed
    start=$(date +%s%N)
    eval "$@" >/dev/null 2>&1
    local exit_code=$?
    end=$(date +%s%N)
    elapsed=$(( (end - start) / 1000000 ))
    echo "$elapsed"
    return $exit_code
}

# Run benchmark N times and return median
benchmark() {
    local label="$1"
    local cmd="$2"
    local times=()

    for i in $(seq 1 "$ITERATIONS"); do
        local t
        t=$(time_cmd "$cmd") || true
        times+=("$t")
    done

    # Sort and get median
    IFS=$'\n' sorted=($(sort -n <<<"${times[*]}")); unset IFS
    local mid=$(( ITERATIONS / 2 ))
    local median="${sorted[$mid]}"

    # Calculate mean
    local sum=0
    for t in "${times[@]}"; do
        sum=$((sum + t))
    done
    local mean=$((sum / ITERATIONS))

    printf "  %-45s median=%5dms  mean=%5dms  [%s]\n" \
        "$label" "$median" "$mean" "$(IFS=,; echo "${times[*]}")"

    RESULTS["$label"]="$median"
}

# ===========================================================================
# Benchmark Suite
# ===========================================================================

echo "=== CRAM + AWS Mountpoint S3 PoC: Performance Benchmark ==="
echo "Date: $(date -Iseconds)"
echo "Iterations: $ITERATIONS"
echo "Reference: ${REF:-none}"
echo ""

# --- Local Baseline ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Local Baseline"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
LOCAL_CRAM="$LOCAL_SAMPLES/${TEST_INTERNAL}.cram"
if [ -f "$LOCAL_CRAM" ]; then
    benchmark "Local: header read" \
        "samtools view -H $REF_OPT '$LOCAL_CRAM'"

    # Detect region from local file
    LOCAL_REGION=$(samtools view -H $REF_OPT "$LOCAL_CRAM" 2>/dev/null | \
        grep '^@SQ' | head -1 | sed 's/.*SN:\([^\t]*\).*/\1/' || echo "")
    if [ -n "$LOCAL_REGION" ]; then
        LOCAL_LEN=$(samtools view -H $REF_OPT "$LOCAL_CRAM" 2>/dev/null | \
            grep '^@SQ' | head -1 | sed 's/.*LN:\([^\t]*\).*/\1/' || echo "100000")
        LOCAL_END=$((LOCAL_LEN < 100000 ? LOCAL_LEN : 100000))
        LOCAL_QUERY="${LOCAL_REGION}:1-${LOCAL_END}"

        benchmark "Local: region query (${LOCAL_QUERY})" \
            "samtools view -c $REF_OPT '$LOCAL_CRAM' '${LOCAL_QUERY}'"
    fi

    benchmark "Local: flagstat (full file)" \
        "samtools flagstat '$LOCAL_CRAM'"
else
    echo "  SKIPPED: Local CRAM not found ($LOCAL_CRAM)"
fi
echo ""

# --- Approach A: Custom FUSE ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Approach A: Custom FUSE (eid_fuse.py)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
FUSE_CRAM="$FUSE_MOUNT/${TEST_EID}.cram"
if mountpoint -q "$FUSE_MOUNT" 2>/dev/null && [ -f "$FUSE_CRAM" ]; then
    benchmark "FUSE: header read" \
        "samtools view -H $REF_OPT '$FUSE_CRAM'"

    if [ -n "${LOCAL_QUERY:-}" ]; then
        benchmark "FUSE: region query (${LOCAL_QUERY})" \
            "samtools view -c $REF_OPT '$FUSE_CRAM' '${LOCAL_QUERY}'"
    fi

    benchmark "FUSE: flagstat (full file)" \
        "samtools flagstat '$FUSE_CRAM'"
else
    echo "  SKIPPED: FUSE not mounted or file not found"
fi
echo ""

# --- Approach B: Symlink Layer ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Approach B: Symlink + Mountpoint S3"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SYMLINK_CRAM="$SYMLINK_MOUNT/${TEST_EID}.cram"
if [ -f "$SYMLINK_CRAM" ]; then
    benchmark "Symlink: header read" \
        "samtools view -H $REF_OPT '$SYMLINK_CRAM'"

    if [ -n "${LOCAL_QUERY:-}" ]; then
        benchmark "Symlink: region query (${LOCAL_QUERY})" \
            "samtools view -c $REF_OPT '$SYMLINK_CRAM' '${LOCAL_QUERY}'"
    fi

    benchmark "Symlink: flagstat (full file)" \
        "samtools flagstat '$SYMLINK_CRAM'"
else
    echo "  SKIPPED: Symlink layer not available or file not found"
fi
echo ""

# --- Approach C: htslib S3 Plugin ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Approach C: htslib S3 Plugin"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
CRAM_ACCESS="$SCRIPT_DIR/cram_access.py"
if [ -f "$CRAM_ACCESS" ]; then
    REF_PY_OPT=""
    [ -n "$REF" ] && REF_PY_OPT="--reference $REF"

    benchmark "S3 Plugin: header read" \
        "python3 '$CRAM_ACCESS' '$TEST_EID' --header-only $REF_PY_OPT --benchmark"

    if [ -n "${LOCAL_QUERY:-}" ]; then
        benchmark "S3 Plugin: region query (${LOCAL_QUERY})" \
            "python3 '$CRAM_ACCESS' '$TEST_EID' '${LOCAL_QUERY}' $REF_PY_OPT --benchmark"
    fi

    benchmark "S3 Plugin: flagstat" \
        "python3 '$CRAM_ACCESS' '$TEST_EID' --command flagstat $REF_PY_OPT --benchmark"
else
    echo "  SKIPPED: cram_access.py not found"
fi
echo ""

# ===========================================================================
# Results Summary Table
# ===========================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results Summary (median, ${ITERATIONS} iterations)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-20s %12s %12s %12s %12s\n" "Test" "Local" "FUSE (A)" "Symlink (B)" "S3 Plugin (C)"
printf "%-20s %12s %12s %12s %12s\n" "----" "-----" "--------" "-----------" "-------------"

for test_type in "header read" "region query" "flagstat"; do
    local_val="${RESULTS["Local: $test_type"]:-N/A}"
    fuse_val="${RESULTS["FUSE: $test_type"]:-N/A}"
    [ "$local_val" != "N/A" ] && local_val="${local_val}ms"
    [ "$fuse_val" != "N/A" ] && fuse_val="${fuse_val}ms"

    # Handle region query with varying suffixes
    symlink_val="N/A"
    s3_val="N/A"
    for key in "${!RESULTS[@]}"; do
        if [[ "$key" == "Symlink: $test_type"* ]]; then
            symlink_val="${RESULTS[$key]}ms"
        fi
        if [[ "$key" == "S3 Plugin: $test_type"* ]]; then
            s3_val="${RESULTS[$key]}ms"
        fi
    done

    # Handle full file variants
    if [ "$test_type" = "flagstat" ]; then
        local_val="${RESULTS["Local: flagstat (full file)"]:-N/A}"
        fuse_val="${RESULTS["FUSE: flagstat (full file)"]:-N/A}"
        symlink_val="${RESULTS["Symlink: flagstat (full file)"]:-N/A}"
        s3_val="${RESULTS["S3 Plugin: flagstat"]:-N/A}"
        [ "$local_val" != "N/A" ] && local_val="${local_val}ms"
        [ "$fuse_val" != "N/A" ] && fuse_val="${fuse_val}ms"
        [ "$symlink_val" != "N/A" ] && symlink_val="${symlink_val}ms"
        [ "$s3_val" != "N/A" ] && s3_val="${s3_val}ms"
    fi

    printf "%-20s %12s %12s %12s %12s\n" "$test_type" "$local_val" "$fuse_val" "$symlink_val" "$s3_val"
done

echo ""

# --- Save results if output file specified ---
if [ -n "$OUTPUT_FILE" ]; then
    {
        echo "# Benchmark Results - $(date -Iseconds)"
        echo "# Iterations: $ITERATIONS"
        echo "#"
        for key in "${!RESULTS[@]}"; do
            echo "$key=${RESULTS[$key]}"
        done
    } > "$OUTPUT_FILE"
    echo "Results saved to: $OUTPUT_FILE"
fi

echo "=== Benchmark complete ==="
