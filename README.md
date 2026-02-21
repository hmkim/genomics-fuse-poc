# genomics-fuse-poc

PoC comparing three approaches for accessing biobank-scale WGS CRAM files on AWS S3, with pseudonymized EID-based identity mapping. Reimplements the [DNAnexus dxfuse](https://github.com/dnanexus/dxfuse) architecture on AWS and benchmarks native alternatives.

## Background

Biobank research platforms (e.g., UK Biobank RAP) use FUSE filesystems to expose large WGS CRAM files (>5 GB each) to researchers. Key requirements:

- **EID mapping**: Researchers access files by project-specific pseudonymized identifiers (`EID_1234567.cram`), while actual data is stored under internal IDs (`internal_id_000001.cram`) — a single copy serves multiple projects.
- **Byte-range reads**: Tools like `samtools` read only the needed genomic regions via CRAM index, so the filesystem must support efficient random access without downloading the full file.
- **FUSE mount**: Cloud storage appears as a local filesystem (`/mnt/project/`), requiring no changes to existing bioinformatics pipelines.

This PoC evaluates whether AWS-native services can replace custom FUSE implementations with better performance, lower operational overhead, and equivalent functionality.

## Three Approaches

| Approach | Implementation | Mount Point | Mechanism |
|----------|---------------|-------------|-----------|
| **A: Custom FUSE** | `scripts/eid_fuse.py` (Python, fusepy + boto3) | `/mnt/project` | SQLite metadata DB + prefetch engine + S3 byte-range reads |
| **B: Symlink + Mountpoint S3** | `scripts/setup_symlink_layer.sh` | `/mnt/project-symlink` | EID symlinks → Mountpoint for Amazon S3 (Rust kernel FUSE) |
| **C: htslib S3 Plugin** | `scripts/cram_access.py` | None (direct S3) | samtools native S3 plugin, no FUSE layer |

### Data Flow

```
samtools view EID_1234567.cram chr22:16M-17M
  → FUSE read() / symlink resolve / S3 plugin
    → EID mapping lookup (SQLite or JSON)
      → S3 GetObject with Range header on internal_id key
```

## Benchmark Results

### Synthetic Data (3.3 MB CRAM, 200K reads)

| Test | Local | Custom FUSE (A) | Symlink+Mountpoint (B) | htslib S3 (C) |
|------|------:|----------------:|-----------------------:|--------------:|
| Header read | 3 ms | 35 ms | **5 ms** | 841 ms |
| Region query | 5 ms | 92 ms | **7 ms** | 864 ms |
| Full flagstat | 27 ms | 416 ms | **31 ms** | 888 ms |

### Real Data — 1000 Genomes (16.4 GB CRAM, 30x WGS)

| Test | Custom FUSE (A) | Symlink+Mountpoint (B) | htslib S3 (C) |
|------|----------------:|-----------------------:|--------------:|
| Header read | 80 ms | **18 ms** | 622 ms |
| Region query (25K reads) | 508 ms | **56 ms** | 1,301 ms |

**Approach B (Symlink + Mountpoint S3) delivers near-local performance** — 1.1–1.7x overhead vs local disk, compared to 4–18x for Custom FUSE and 23–280x for htslib S3 plugin.

### Byte-Range Integrity

All approaches pass bit-for-bit MD5 verification across 9 test ranges (magic bytes, headers, random offsets up to 15 GB, EOF markers) — confirming correct CRAM slice decoding via all access paths.

## Architecture

### Custom FUSE (`eid_fuse.py`) — dxfuse Reimplementation

The 994-line Python FUSE mirrors the core architecture of the [dxfuse Go codebase](https://github.com/dnanexus/dxfuse):

| dxfuse (Go) | eid_fuse.py | Purpose |
|---|---|---|
| `metadata_db.go` (SQLite 3 tables) | SQLite shared-memory DB | Inode / namespace / directory resolution |
| `dxfuse.go` FileHandle + fhTable | `file_handles` dict | Open file state with presigned URLs |
| `prefetch.go` state machine | `PrefetchManager` | Sequential access detection: NIL → DETECT_SEQ → PREFETCH → EOF |
| `dx_ops.go` DxDownloadURL | S3 presigned URL generation | Download URL provisioning |
| HTTP Range requests | S3 GetObject with Range header | Byte-range reads |

### CDK Infrastructure (`infra/`)

Five CloudFormation stacks deployed via `cd infra && npx cdk deploy --all`:

| Stack | Resources |
|-------|-----------|
| `genomics-network` | VPC (2 AZs), S3/DynamoDB Gateway Endpoints |
| `genomics-storage` | S3 data bucket, KMS encryption, CloudTrail audit |
| `genomics-database` | DynamoDB EID mapping table (PK: `project_id`, SK: `eid`, GSI: `internal_id-index`) |
| `genomics-auth` | Cognito User Pool + Identity Pool, per-project IAM roles |
| `genomics-compute` | Lambda functions (eid-resolver, session-init, data-seeder), EC2 workstation |

### Recommended Production Architecture

Combines **Approach B performance** with **dynamic EID mapping**:

```
Researcher login (Cognito)
  → Identity Pool: project-scoped IAM Role
    → Lambda: generate EID mappings from DynamoDB
      → Mountpoint S3 mount (Rust kernel FUSE + SSD cache)
        → Auto-generate symlinks (EID → internal_id)
          → /mnt/project/EID_XXXXXXX.cram ready
```

## Quick Start

### Prerequisites

- Amazon Linux 2023 on EC2 (ap-northeast-2)
- IAM role with S3 read access to the data bucket

### Setup

```bash
# 1. Install tools (samtools 1.21, mount-s3, fusepy)
sudo bash scripts/01_install_tools.sh

# 2. Generate synthetic test data (3 CRAM files, ~3.3 MB each)
bash scripts/02_generate_cram.sh

# 3. Create S3 bucket and upload data
bash scripts/03_setup_s3.sh

# 4. Mount S3 via Mountpoint
sudo bash scripts/04_mount_s3.sh mount
```

### Run the Three Approaches

```bash
# Approach A: Custom FUSE
python3 scripts/eid_fuse.py /mnt/project \
  --bucket <YOUR_BUCKET_NAME> \
  --project project_001

# Approach B: Symlink + Mountpoint S3
bash scripts/setup_symlink_layer.sh project_001 /mnt/project-symlink

# Approach C: htslib S3 plugin (no FUSE)
python3 scripts/cram_access.py EID_1234567 chr22:16M-17M \
  --reference data/reference/GRCh38_chr22.fa
```

### Tests and Benchmarks

```bash
bash scripts/run_tests.sh all             # Full test suite (17 tests)
bash scripts/run_tests.sh approach_b      # Single approach
bash scripts/benchmark.sh --iterations 5  # Performance comparison
python3 scripts/verify_byte_range.py      # Byte-range MD5 verification
```

### Interactive Demo

```bash
# Set up demo mount points (5 configurations)
sudo bash scripts/demo_mount_setup.sh mount

# Run interactive demo (5 scenarios)
bash scripts/demo_mountpoint.sh              # Interactive (Enter to advance)
bash scripts/demo_mountpoint.sh --auto       # Auto-advance
bash scripts/demo_mountpoint.sh --scenario 3 # Specific scenario only
bash scripts/demo_mountpoint.sh --1kg        # Use 1000 Genomes data (15+ GB)
```

### Deploy CDK Infrastructure

```bash
cd infra
npm install
# Set your account ID in lib/config/constants.ts or via environment:
export CDK_DEFAULT_ACCOUNT=<YOUR_ACCOUNT_ID>
npx cdk deploy --all
```

## Project Structure

```
├── scripts/
│   ├── eid_fuse.py              # Approach A: Custom FUSE (dxfuse reimplementation)
│   ├── setup_symlink_layer.sh   # Approach B: EID symlink layer
│   ├── cram_access.py           # Approach C: htslib S3 plugin wrapper
│   ├── 01_install_tools.sh      # Tool installation (samtools, mount-s3)
│   ├── 02_generate_cram.sh      # Synthetic CRAM data generation
│   ├── 03_setup_s3.sh           # S3 bucket setup and upload
│   ├── 04_mount_s3.sh           # Mountpoint S3 management
│   ├── run_tests.sh             # Functional test suite
│   ├── benchmark.sh             # Performance benchmarks
│   ├── verify_byte_range.py     # Byte-range integrity verification
│   ├── demo_mount_setup.sh      # Demo mount configurations
│   └── demo_mountpoint.sh       # Interactive demo (5 scenarios)
├── infra/
│   ├── bin/app.ts               # CDK app entry point
│   ├── lib/config/constants.ts  # Environment configuration
│   ├── lib/stacks/              # 5 CDK stacks (network, storage, database, auth, compute)
│   ├── lambda/                  # Lambda functions (eid-resolver, session-init, data-seeder)
│   └── test/                    # CDK assertions tests
├── data/mapping/
│   ├── eid_mapping.json         # EID → internal_id mapping (synthetic)
│   └── eid_mapping_1kg.json     # EID → internal_id mapping (1000 Genomes)
├── REPORT.md                    # Full technical report (Korean)
└── CLAUDE.md                    # AI assistant guidance
```

## EID Mapping

Researchers see pseudonymized EIDs; the same underlying file can map to different EIDs across projects:

```json
{
  "project_001": {
    "EID_1234567": "internal_id_000001",
    "EID_2345678": "internal_id_000002"
  },
  "project_002": {
    "EID_9876543": "internal_id_000001"
  }
}
```

`internal_id_000001.cram` is stored once in S3 but accessible as `EID_1234567.cram` in project_001 and `EID_9876543.cram` in project_002 — **one copy, multiple mappings**.

## Test Data

| Dataset | Size | Description |
|---------|------|-------------|
| Synthetic | 3 × 3.3 MB | 100K paired-end reads on chr22 (wgsim-generated) |
| 1000 Genomes | 3 × 14–17 GB | HG00096, NA06985, NA06986 — real 30x WGS |

Genomic data files (CRAM, CRAI, FA) are excluded from this repository via `.gitignore`. Generate synthetic data with `scripts/02_generate_cram.sh` or download 1000 Genomes samples separately.

## Technologies

- **Python 3** — Custom FUSE, S3 access wrapper, byte-range verifier (`fusepy`, `boto3`)
- **Bash** — Setup, test, and benchmark scripts
- **TypeScript** — CDK infrastructure and Lambda handlers
- **Rust** — Mountpoint for Amazon S3 (AWS-maintained)
- **samtools/htslib 1.21** — CRAM file processing (compiled with `--enable-s3`)

## License

This project is provided as-is for evaluation and research purposes.
