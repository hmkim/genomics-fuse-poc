#!/usr/bin/env bash
# demo_mount_setup.sh - S3 Mountpoint 데모용 마운트 설정
#
# 기존 04_mount_s3.sh 와 별도로, 데모 시나리오에 맞는 다양한 마운트 구성을 제공.
#
# 마운트 포인트:
#   /mnt/demo-genomics       - 전체 버킷 마운트 (디렉토리 탐색용)
#   /mnt/demo-cram           - CRAM 데이터만 (prefix: internal/cram/)
#   /mnt/demo-cram-cached    - CRAM 데이터 + 디스크 캐시 (반복 접근 데모용)
#   /mnt/demo-reference      - 참조 게놈 (prefix: reference/GRCh38/)
#   /mnt/demo-symlink        - EID 심볼릭 링크 레이어
#
# Usage:
#   sudo bash scripts/demo_mount_setup.sh [mount|unmount|status]

set -euo pipefail

# Set your S3 bucket name below (default: genomics-poc-<YOUR_ACCOUNT_ID>)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "<YOUR_ACCOUNT_ID>")
BUCKET_NAME="${BUCKET_NAME:-genomics-poc-${ACCOUNT_ID}}"
REGION="ap-northeast-2"

MOUNT_GENOMICS="/mnt/demo-genomics"
MOUNT_CRAM="/mnt/demo-cram"
MOUNT_CRAM_CACHED="/mnt/demo-cram-cached"
MOUNT_REFERENCE="/mnt/demo-reference"
MOUNT_SYMLINK="/mnt/demo-symlink"

CACHE_DIR="/tmp/demo-mountpoint-cache"
LOG_DIR="/var/log/demo-mount-s3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MAPPING_FILE="$PROJECT_DIR/data/mapping/eid_mapping.json"

ACTION="${1:-mount}"

info() { echo -e "\033[1;36m[INFO]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m   $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m  $*"; }

do_mount() {
    echo "========================================"
    echo "  S3 Mountpoint 데모 환경 설정"
    echo "========================================"
    echo "Bucket: $BUCKET_NAME"
    echo "Region: $REGION"
    echo ""

    if ! command -v mount-s3 &>/dev/null; then
        err "mount-s3 not installed. Run: sudo bash scripts/01_install_tools.sh"
        exit 1
    fi

    info "mount-s3 version: $(mount-s3 --version 2>&1)"
    echo ""

    sudo mkdir -p "$MOUNT_GENOMICS" "$MOUNT_CRAM" "$MOUNT_CRAM_CACHED" \
                  "$MOUNT_REFERENCE" "$MOUNT_SYMLINK" \
                  "$CACHE_DIR/cram" "$CACHE_DIR/reference" "$LOG_DIR"

    # --- Mount 1: 전체 버킷 (디렉토리 탐색 데모) ---
    info "[1/4] 전체 버킷 마운트: $MOUNT_GENOMICS"
    if mountpoint -q "$MOUNT_GENOMICS" 2>/dev/null; then
        ok "이미 마운트됨"
    else
        mount-s3 "$BUCKET_NAME" "$MOUNT_GENOMICS" \
            --read-only \
            --region "$REGION" \
            --allow-other \
            --log-directory "$LOG_DIR" \
            --metadata-ttl 300 \
            --max-threads 16
        ok "s3://$BUCKET_NAME/ -> $MOUNT_GENOMICS"
    fi

    # --- Mount 2: CRAM 데이터 (캐시 없음 - 순수 S3 성능 측정용) ---
    info "[2/4] CRAM 데이터 마운트 (no cache): $MOUNT_CRAM"
    if mountpoint -q "$MOUNT_CRAM" 2>/dev/null; then
        ok "이미 마운트됨"
    else
        mount-s3 "$BUCKET_NAME" "$MOUNT_CRAM" \
            --read-only \
            --region "$REGION" \
            --prefix "internal/cram/" \
            --allow-other \
            --log-directory "$LOG_DIR" \
            --metadata-ttl 3600 \
            --max-threads 16
        ok "s3://$BUCKET_NAME/internal/cram/ -> $MOUNT_CRAM"
    fi

    # --- Mount 3: CRAM 데이터 + 디스크 캐시 (반복 접근 성능 비교용) ---
    info "[3/4] CRAM 데이터 마운트 (cached): $MOUNT_CRAM_CACHED"
    if mountpoint -q "$MOUNT_CRAM_CACHED" 2>/dev/null; then
        ok "이미 마운트됨"
    else
        mount-s3 "$BUCKET_NAME" "$MOUNT_CRAM_CACHED" \
            --read-only \
            --region "$REGION" \
            --prefix "internal/cram/" \
            --allow-other \
            --log-directory "$LOG_DIR" \
            --cache "$CACHE_DIR/cram" \
            --metadata-ttl 3600 \
            --max-threads 16
        ok "s3://$BUCKET_NAME/internal/cram/ (cached) -> $MOUNT_CRAM_CACHED"
    fi

    # --- Mount 4: 참조 게놈 (indefinite TTL - 변경 없는 데이터) ---
    info "[4/4] 참조 게놈 마운트: $MOUNT_REFERENCE"
    if mountpoint -q "$MOUNT_REFERENCE" 2>/dev/null; then
        ok "이미 마운트됨"
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
        ok "s3://$BUCKET_NAME/reference/GRCh38/ -> $MOUNT_REFERENCE"
    fi

    # --- Symlink 레이어 구성 ---
    info "[+] EID 심볼릭 링크 레이어: $MOUNT_SYMLINK"
    setup_symlinks

    echo ""
    echo "========================================"
    info "마운트 완료. 상태 확인:"
    do_status
}

setup_symlinks() {
    if [ ! -f "$MAPPING_FILE" ]; then
        err "매핑 파일 없음: $MAPPING_FILE"
        return 1
    fi

    # project_001의 EID 매핑으로 심볼릭 링크 생성
    sudo rm -rf "$MOUNT_SYMLINK"/*

    local project="project_001"
    local count=0

    # jq가 없으면 python으로 파싱
    if command -v jq &>/dev/null; then
        for eid in $(jq -r ".[\"$project\"] | keys[]" "$MAPPING_FILE"); do
            local internal_id=$(jq -r ".[\"$project\"][\"$eid\"]" "$MAPPING_FILE")
            ln -sf "$MOUNT_CRAM/${internal_id}.cram" "$MOUNT_SYMLINK/${eid}.cram"
            ln -sf "$MOUNT_CRAM/${internal_id}.cram.crai" "$MOUNT_SYMLINK/${eid}.cram.crai"
            count=$((count + 1))
        done
    else
        python3 -c "
import json, os
with open('$MAPPING_FILE') as f:
    m = json.load(f)
for eid, iid in m.get('$project', {}).items():
    os.symlink('$MOUNT_CRAM/{}.cram'.format(iid), '$MOUNT_SYMLINK/{}.cram'.format(eid))
    os.symlink('$MOUNT_CRAM/{}.cram.crai'.format(iid), '$MOUNT_SYMLINK/{}.cram.crai'.format(eid))
    print(f'  {eid}.cram -> {iid}.cram')
"
        count=$(ls "$MOUNT_SYMLINK"/*.cram 2>/dev/null | wc -l)
    fi

    ok "EID 심볼릭 링크 ${count}개 생성 (project: $project)"
}

do_unmount() {
    echo "========================================"
    echo "  S3 Mountpoint 데모 환경 해제"
    echo "========================================"

    for mp in "$MOUNT_GENOMICS" "$MOUNT_CRAM" "$MOUNT_CRAM_CACHED" "$MOUNT_REFERENCE"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            sudo umount "$mp"
            ok "Unmounted: $mp"
        else
            info "Not mounted: $mp"
        fi
    done

    # 심볼릭 링크 정리
    if [ -d "$MOUNT_SYMLINK" ]; then
        sudo rm -rf "$MOUNT_SYMLINK"/*
        ok "Symlinks cleaned: $MOUNT_SYMLINK"
    fi

    # 캐시 정리
    if [ -d "$CACHE_DIR" ]; then
        sudo rm -rf "$CACHE_DIR"
        ok "Cache cleaned: $CACHE_DIR"
    fi

    echo ""
    ok "데모 환경 해제 완료"
}

do_status() {
    echo ""
    echo "=== 마운트 상태 ==="
    for mp in "$MOUNT_GENOMICS" "$MOUNT_CRAM" "$MOUNT_CRAM_CACHED" "$MOUNT_REFERENCE"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            local file_count=$(ls "$mp"/ 2>/dev/null | wc -l)
            echo -e "  \033[1;32mMOUNTED\033[0m  $mp  (files: $file_count)"
        else
            echo -e "  \033[1;31mNOT MOUNTED\033[0m  $mp"
        fi
    done

    echo ""
    echo "=== 심볼릭 링크 ==="
    local link_count=$(ls "$MOUNT_SYMLINK"/*.cram 2>/dev/null | wc -l)
    echo "  $MOUNT_SYMLINK: ${link_count}개 EID 링크"

    echo ""
    echo "=== 캐시 사용량 ==="
    du -sh "$CACHE_DIR"/* 2>/dev/null || echo "  캐시 없음"

    echo ""
    echo "=== mount-s3 프로세스 ==="
    ps aux | grep '[m]ount-s3' | awk '{print "  PID="$2, $11, $12, $13}' || echo "  실행 중인 프로세스 없음"
}

case "$ACTION" in
    mount)    do_mount ;;
    unmount)  do_unmount ;;
    status)   do_status ;;
    *)
        echo "Usage: sudo bash $0 [mount|unmount|status]"
        exit 1
        ;;
esac
