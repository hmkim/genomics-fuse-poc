# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PoC comparing three approaches for accessing UK Biobank-style WGS CRAM files (>5GB each) stored in AWS S3, with EID-based identity mapping. The project reimplements DNAnexus dxfuse architecture on AWS and benchmarks alternatives.

**Target environment:** Amazon Linux 2023, EC2 in ap-northeast-2, S3 bucket `<YOUR_BUCKET_NAME>`.

## Common Commands

### Setup (run in order)
```bash
sudo bash scripts/01_install_tools.sh    # samtools, htslib, mount-s3, fusepy
bash scripts/02_generate_cram.sh          # Synthetic CRAM samples in data/samples/
bash scripts/03_setup_s3.sh               # Upload data to S3
sudo bash scripts/04_mount_s3.sh mount    # Mount S3 via Mountpoint (/mnt/s3-internal, /mnt/s3-reference)
```

### Running the three approaches
```bash
# Approach A: Custom FUSE
python3 scripts/eid_fuse.py /mnt/project --bucket <YOUR_BUCKET_NAME> --project project_001 --mapping data/mapping/eid_mapping.json

# Approach B: Symlink layer (requires 04_mount_s3.sh)
bash scripts/setup_symlink_layer.sh project_001 /mnt/project-symlink

# Approach C: htslib S3 plugin (no FUSE, direct S3 access)
python3 scripts/cram_access.py EID_1234567 chr22:16M-17M --reference data/reference/GRCh38_chr22.fa
```

### Tests and benchmarks
```bash
bash scripts/run_tests.sh all                     # Full test suite
bash scripts/run_tests.sh approach_a              # Single approach (a, b, c, local)
bash scripts/benchmark.sh --iterations 5          # Performance benchmark
python3 scripts/verify_byte_range.py              # Byte-range read verification
```

### Mountpoint management
```bash
sudo bash scripts/04_mount_s3.sh status    # Check mount status
sudo bash scripts/04_mount_s3.sh unmount   # Unmount
```

## Architecture

### Three approaches compared

| Approach | Implementation | Mount Point | Key Mechanism |
|----------|---------------|-------------|---------------|
| A: Custom FUSE | `scripts/eid_fuse.py` (Python, fusepy+boto3) | `/mnt/project` | SQLite metadata + prefetch engine + S3 byte-range |
| B: Symlink + Mountpoint S3 | `scripts/setup_symlink_layer.sh` | `/mnt/project-symlink` | EID symlinks -> Mountpoint S3 (Rust kernel FUSE) |
| C: htslib S3 Plugin | `scripts/cram_access.py` | None (direct S3) | samtools native S3 plugin, no FUSE |

### eid_fuse.py architecture (mirrors dxfuse Go codebase)

The custom FUSE (`scripts/eid_fuse.py`, 994 lines) reimplements the `dxfuse/` Go project's core architecture:

| dxfuse (Go) | eid_fuse.py equivalent | Purpose |
|---|---|---|
| `metadata_db.go` SQLite 3 tables | SQLite shared-memory DB | inode/namespace/directory resolution |
| `dxfuse.go` FileHandle + fhTable | `file_handles` dict | Open file state with presigned URLs |
| `prefetch.go` state machine | `PrefetchManager` | Sequential access detection: NIL -> DETECT_SEQ -> PREFETCH_IN_PROGRESS -> EOF |
| `dx_ops.go` DxDownloadURL | S3 presigned URL generation | Download URL provisioning |
| HTTP Range requests | S3 GetObject with Range header | Byte-range reads |

### Data flow
```
samtools view EID_1234567.cram chr22:16M-17M
  -> FUSE read() / symlink resolve / S3 plugin
    -> EID mapping lookup (SQLite or JSON)
      -> S3 GetObject with Range header on internal_id key
```

### Key data files
- `data/mapping/eid_mapping.json` / `eid_mapping_1kg.json` — EID-to-internal-ID mapping per project
- `data/samples/` — Synthetic CRAM files (~3.3 MB each, chr22)
- `data/samples_1kg/` — Real 1000 Genomes CRAM files (14-17 GB each)
- `data/reference/` — GRCh38 reference genome (chr22 subset and full)

### dxfuse/ subdirectory
Cloned DNAnexus dxfuse project (Go). Built with `make` (see `dxfuse/Makefile`). The Python PoC scripts reference its architecture but do not import or call it directly. Key source: `dxfuse.go`, `metadata_db.go`, `prefetch.go`.

## CDK Infrastructure (`infra/`)

Five stacks deployed via `cd infra && npx cdk deploy --all`:

| Stack | Key Resources |
|-------|--------------|
| `genomics-network` | VPC (10.0.0.0/16, 2 AZs), S3 Gateway Endpoint, DynamoDB Gateway Endpoint |
| `genomics-storage` | KMS key, data bucket (`genomics-data-<YOUR_ACCOUNT_ID>`), log bucket, CloudTrail |
| `genomics-database` | DynamoDB `genomics-eid-mapping` (PK: `project_id`, SK: `eid`, GSI: `internal_id-index`) |
| `genomics-auth` | Cognito User Pool + Identity Pool, per-project IAM roles with S3/DynamoDB scoping |
| `genomics-compute` | Lambda (eid-resolver, session-init, data-seeder), EC2 workstation (t3.large) |

Config lives in `infra/lib/config/constants.ts`. Projects: `project_001`, `project_002`, `project_1kg`.

### Lambda functions (`infra/lambda/`)
- **eid-resolver** — `{ project_id, eid }` → `{ internal_id, s3_key, s3_uri }`
- **session-init** — `{ project_id, user_id }` → paginated EID mappings + mount_config
- **data-seeder** — Batch-write EID mappings from inline data or S3 JSON

## Language and dependencies

- **Python 3** — eid_fuse.py, cram_access.py, verify_byte_range.py (requires `fusepy`, `boto3`)
- **Bash** — Setup/test/benchmark scripts
- **TypeScript** — CDK stacks and Lambda handlers (`infra/`)
- **Go** — dxfuse/ reference codebase (Go 1.23+, `github.com/jacobsa/fuse`, `github.com/mattn/go-sqlite3`)
- **samtools/htslib** — CRAM file processing (must be installed on the system)

## S3 bucket structure
```
s3://<YOUR_BUCKET_NAME>/
├── internal/cram/          # CRAM master data (internal_id keys)
├── reference/GRCh38/       # Reference genome
└── metadata/eid_mapping/   # EID mapping JSON files
```

## Data variants

- **Synthetic** (`data/samples/`): 3 CRAM files ~3.3 MB each, 100K reads on chr22
- **1000 Genomes** (`data/samples_1kg/`): 3 real CRAM files 14–17 GB each (HG00096, NA06985, NA06986), mapping in `eid_mapping_1kg.json`

## Report language

The main report (`REPORT.md`) and documentation are written in Korean.
