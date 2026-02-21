#!/usr/bin/env bash
# 02_generate_cram.sh - Generate synthetic CRAM test data
#
# Creates 3 synthetic samples with chr22 reference for PoC testing.
# Each sample: ~100K paired-end reads aligned to chr22.
#
# Output:
#   data/reference/GRCh38_chr22.fa      - chr22 reference sequence
#   data/reference/GRCh38_chr22.fa.fai  - FASTA index
#   data/samples/internal_id_000001.cram + .crai
#   data/samples/internal_id_000002.cram + .crai
#   data/samples/internal_id_000003.cram + .crai

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/data"
REF_DIR="$DATA_DIR/reference"
SAMPLES_DIR="$DATA_DIR/samples"
TMP_DIR="$DATA_DIR/tmp"

NUM_READS=100000  # 100K paired-end reads per sample
NUM_SAMPLES=3
CHR="chr22"
CHR_LENGTH=50818468  # GRCh38 chr22 length

echo "=== Synthetic CRAM Data Generation ==="
echo "Samples: $NUM_SAMPLES x $NUM_READS paired-end reads"
echo ""

mkdir -p "$REF_DIR" "$SAMPLES_DIR" "$TMP_DIR"

# --- Step 1: Get chr22 reference ---
echo "[Step 1] Preparing chr22 reference genome..."
REF_FA="$REF_DIR/GRCh38_chr22.fa"

if [ -f "$REF_FA" ] && [ -f "${REF_FA}.fai" ]; then
    echo "  Reference already exists: $REF_FA"
else
    # Try downloading from UCSC or generate a synthetic one
    echo "  Downloading chr22 reference from UCSC..."
    REF_URL="https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/chr22.fa.gz"

    if wget -q --spider "$REF_URL" 2>/dev/null; then
        wget -q -O "${REF_FA}.gz" "$REF_URL"
        gunzip -f "${REF_FA}.gz"
        echo "  Downloaded chr22 reference ($(du -h "$REF_FA" | cut -f1))"
    else
        echo "  UCSC download failed, generating synthetic chr22 reference..."
        # Generate a synthetic reference with realistic-ish sequence
        python3 -c "
import random
random.seed(42)
seq_len = $CHR_LENGTH // 100  # Use 1/100th size for PoC (still ~500KB)
bases = 'ACGT'
print('>chr22')
seq = ''.join(random.choice(bases) for _ in range(seq_len))
for i in range(0, len(seq), 80):
    print(seq[i:i+80])
" > "$REF_FA"
        echo "  Generated synthetic chr22 reference ($(du -h "$REF_FA" | cut -f1))"
    fi

    # Index the reference
    samtools faidx "$REF_FA"
    echo "  Indexed reference: ${REF_FA}.fai"
fi

# Get actual reference length from .fai
REF_LENGTH=$(awk '{print $2}' "${REF_FA}.fai" | head -1)
echo "  Reference length: $REF_LENGTH bp"
echo ""

# --- Step 2: Generate synthetic reads and CRAM files ---
echo "[Step 2] Generating synthetic CRAM files..."

for i in $(seq 1 $NUM_SAMPLES); do
    SAMPLE_ID=$(printf "internal_id_%06d" "$i")
    CRAM_FILE="$SAMPLES_DIR/${SAMPLE_ID}.cram"
    CRAI_FILE="$SAMPLES_DIR/${SAMPLE_ID}.cram.crai"

    if [ -f "$CRAM_FILE" ] && [ -f "$CRAI_FILE" ]; then
        echo "  [$i/$NUM_SAMPLES] $SAMPLE_ID already exists, skipping"
        continue
    fi

    echo "  [$i/$NUM_SAMPLES] Generating $SAMPLE_ID..."

    # Generate synthetic SAM data using Python (portable, no wgsim/bwa dependency)
    SAM_FILE="$TMP_DIR/${SAMPLE_ID}.sam"
    SORTED_BAM="$TMP_DIR/${SAMPLE_ID}.sorted.bam"

    python3 -c "
import random
random.seed($i * 1000)

ref_len = $REF_LENGTH
read_len = 150
num_reads = $NUM_READS
sample_id = '$SAMPLE_ID'
chr_name = '${CHR}'

# Read the reference for actual sequence
with open('$REF_FA') as f:
    lines = f.readlines()
ref_seq = ''.join(line.strip() for line in lines if not line.startswith('>'))

print('@HD\tVN:1.6\tSO:coordinate')
print(f'@SQ\tSN:{chr_name}\tLN:{ref_len}')
print(f'@RG\tID:{sample_id}\tSM:{sample_id}\tPL:ILLUMINA\tLB:lib1')

bases = 'ACGT'
for r in range(num_reads):
    pos = random.randint(1, max(1, ref_len - read_len * 2 - 500))
    insert_size = random.randint(200, 500)
    mapq = random.randint(20, 60)

    # Read 1 (forward)
    seq1_start = pos - 1
    seq1_end = min(seq1_start + read_len, len(ref_seq))
    seq1 = ref_seq[seq1_start:seq1_end]
    if len(seq1) < read_len:
        seq1 += ''.join(random.choice(bases) for _ in range(read_len - len(seq1)))
    qual1 = 'I' * read_len  # High quality

    # Read 2 (reverse)
    mate_pos = pos + insert_size
    seq2_start = min(mate_pos - 1, len(ref_seq) - read_len)
    seq2_end = min(seq2_start + read_len, len(ref_seq))
    seq2 = ref_seq[max(0, seq2_start):seq2_end]
    if len(seq2) < read_len:
        seq2 += ''.join(random.choice(bases) for _ in range(read_len - len(seq2)))
    # Simple reverse complement
    comp = {'A':'T', 'T':'A', 'C':'G', 'G':'C', 'N':'N'}
    seq2_rc = ''.join(comp.get(b, 'N') for b in reversed(seq2))
    qual2 = 'I' * read_len

    read_name = f'read_{r:07d}'

    # Read 1: flag=99 (paired, proper pair, mate reverse, first in pair)
    print(f'{read_name}\t99\t{chr_name}\t{pos}\t{mapq}\t{read_len}M\t=\t{mate_pos}\t{insert_size}\t{seq1}\t{qual1}\tRG:Z:{sample_id}')
    # Read 2: flag=147 (paired, proper pair, reverse, second in pair)
    print(f'{read_name}\t147\t{chr_name}\t{mate_pos}\t{mapq}\t{read_len}M\t=\t{pos}\t{-insert_size}\t{seq2_rc}\t{qual2}\tRG:Z:{sample_id}')
" > "$SAM_FILE"

    echo "    Generated SAM: $(wc -l < "$SAM_FILE") lines"

    # Sort SAM -> BAM
    samtools sort -@ 2 -o "$SORTED_BAM" "$SAM_FILE"
    echo "    Sorted BAM: $(du -h "$SORTED_BAM" | cut -f1)"

    # Convert BAM -> CRAM (with reference)
    samtools view -C -T "$REF_FA" -o "$CRAM_FILE" "$SORTED_BAM"
    echo "    CRAM: $(du -h "$CRAM_FILE" | cut -f1)"

    # Index CRAM
    samtools index "$CRAM_FILE"
    echo "    CRAI index created"

    # Validate
    samtools quickcheck "$CRAM_FILE" && echo "    Validation: OK" || echo "    Validation: FAILED"

    # Clean up temp files
    rm -f "$SAM_FILE" "$SORTED_BAM"
done

# Clean up tmp directory
rmdir "$TMP_DIR" 2>/dev/null || true

echo ""

# --- Step 3: Verify output ---
echo "[Step 3] Verification..."
echo ""
echo "Generated files:"
ls -lh "$SAMPLES_DIR"/ 2>/dev/null || echo "  No files found"
echo ""
echo "Reference files:"
ls -lh "$REF_DIR"/ 2>/dev/null || echo "  No files found"
echo ""

# Quick sanity check on first sample
FIRST_CRAM="$SAMPLES_DIR/internal_id_000001.cram"
if [ -f "$FIRST_CRAM" ]; then
    echo "Sample verification (internal_id_000001):"
    echo "  Header RG: $(samtools view -H "$FIRST_CRAM" | grep '^@RG')"
    echo "  Total reads: $(samtools view -c "$FIRST_CRAM")"
    echo "  Flagstat:"
    samtools flagstat "$FIRST_CRAM" | head -3 | sed 's/^/    /'
fi

echo ""
echo "=== CRAM data generation complete ==="
