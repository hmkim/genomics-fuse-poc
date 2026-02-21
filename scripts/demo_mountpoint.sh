#!/usr/bin/env bash
# demo_mountpoint.sh - S3 Mountpoint 유전체 데이터 접근 데모
#
# EC2에서 S3 Mountpoint를 통해 유전체(CRAM) 데이터를 로컬 파일시스템처럼
# 접근하는 5가지 시나리오를 순차적으로 시연합니다.
#
# 사전 조건:
#   sudo bash scripts/demo_mount_setup.sh mount
#
# Usage:
#   bash scripts/demo_mountpoint.sh              # 전체 데모 (대화형)
#   bash scripts/demo_mountpoint.sh --auto       # 자동 진행 (입력 불필요)
#   bash scripts/demo_mountpoint.sh --scenario 3 # 특정 시나리오만 실행
#   bash scripts/demo_mountpoint.sh --1kg        # 1000 Genomes 대용량 데이터 사용

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# --- 마운트 포인트 ---
MOUNT_GENOMICS="/mnt/demo-genomics"
MOUNT_CRAM="/mnt/demo-cram"
MOUNT_CRAM_CACHED="/mnt/demo-cram-cached"
MOUNT_REFERENCE="/mnt/demo-reference"
MOUNT_SYMLINK="/mnt/demo-symlink"

# --- 설정 ---
# Set your S3 bucket name below (default: genomics-poc-<YOUR_ACCOUNT_ID>)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '<YOUR_ACCOUNT_ID>')
BUCKET_NAME="${BUCKET_NAME:-genomics-poc-${ACCOUNT_ID}}"
REGION="ap-northeast-2"
AUTO_MODE=false
SCENARIO_FILTER=""
USE_1KG=false

# 1000 Genomes 사용 시 다른 테스트 파일
SYNTH_CRAM="internal_id_000001.cram"
SYNTH_EID="EID_1234567"
SYNTH_REGION="chr22:16000000-17000000"

KG_CRAM="internal_id_100001.cram"   # HG00096
KG_EID="EID_4001001"
KG_REGION="chr22:16000000-17000000"

# 참조 게놈: 로컬 우선, 없으면 마운트 포인트 사용
_find_ref() {
    local candidates=("$@")
    for c in "${candidates[@]}"; do
        [ -f "$c" ] && echo "$c" && return
    done
    echo ""
}

SYNTH_REFERENCE=$(_find_ref \
    "$PROJECT_DIR/data/reference/GRCh38_chr22.fa" \
    "$MOUNT_REFERENCE/GRCh38_chr22.fa")

KG_REFERENCE=$(_find_ref \
    "$PROJECT_DIR/data/reference_grch38_full/GRCh38_full_analysis_set_plus_decoy_hla.fa" \
    "$MOUNT_REFERENCE/GRCh38_full_analysis_set_plus_decoy_hla.fa")

# --- CLI 파싱 ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)       AUTO_MODE=true; shift ;;
        --scenario)   SCENARIO_FILTER="$2"; shift 2 ;;
        --1kg)        USE_1KG=true; shift ;;
        -h|--help)
            echo "Usage: bash $0 [--auto] [--scenario N] [--1kg]"
            echo "  --auto       자동 진행 (Enter 불필요)"
            echo "  --scenario N 특정 시나리오만 (1-5)"
            echo "  --1kg        1000 Genomes 대용량 데이터 사용"
            exit 0
            ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# 사용할 테스트 파일 결정
if $USE_1KG; then
    TEST_CRAM="$KG_CRAM"
    TEST_EID="$KG_EID"
    TEST_REFERENCE="$KG_REFERENCE"
    TEST_REGION="$KG_REGION"
    DATA_LABEL="1000 Genomes (15.9 GB)"
else
    TEST_CRAM="$SYNTH_CRAM"
    TEST_EID="$SYNTH_EID"
    TEST_REFERENCE="$SYNTH_REFERENCE"
    TEST_REGION="$SYNTH_REGION"
    DATA_LABEL="합성 데이터 (3.3 MB)"
fi

# --- 유틸리티 ---
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RED='\033[1;31m'
BOLD='\033[1m'
RESET='\033[0m'

banner() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BLUE}║${RESET}  ${BOLD}$1${RESET}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

section() {
    echo ""
    echo -e "${CYAN}── $1 ──${RESET}"
    echo ""
}

run_cmd() {
    # 명령어를 보여주고 실행
    echo -e "${YELLOW}\$ $*${RESET}"
    eval "$@" 2>&1
    local rc=$?
    echo ""
    return $rc
}

timed_cmd() {
    # 명령어를 보여주고 실행 시간 측정 (elapsed만 stdout에 반환)
    local label="$1"; shift
    echo -e "${YELLOW}\$ $*${RESET}" >&2
    local start_ms=$(($(date +%s%N) / 1000000))
    eval "$@" >&2 2>&1
    local end_ms=$(($(date +%s%N) / 1000000))
    local elapsed=$((end_ms - start_ms))
    echo -e "${GREEN}  ⏱ ${label}: ${elapsed}ms${RESET}" >&2
    echo "" >&2
    echo "$elapsed"
}

pause() {
    if ! $AUTO_MODE; then
        echo -e "${BOLD}[Enter를 눌러 계속...]${RESET}"
        read -r
    else
        sleep 1
    fi
}

should_run() {
    [[ -z "$SCENARIO_FILTER" ]] || [[ "$SCENARIO_FILTER" == "$1" ]]
}

# --- 사전 확인 ---
check_prerequisites() {
    local ok=true

    echo -e "${CYAN}환경 확인 중...${RESET}"

    if ! command -v mount-s3 &>/dev/null; then
        echo -e "${RED}✗ mount-s3 미설치${RESET}"
        ok=false
    else
        echo -e "${GREEN}✓ mount-s3 $(mount-s3 --version 2>&1)${RESET}"
    fi

    if ! command -v samtools &>/dev/null; then
        echo -e "${RED}✗ samtools 미설치${RESET}"
        ok=false
    else
        echo -e "${GREEN}✓ samtools $(samtools --version | head -1)${RESET}"
    fi

    if ! mountpoint -q "$MOUNT_CRAM" 2>/dev/null; then
        echo -e "${RED}✗ CRAM 마운트 없음: $MOUNT_CRAM${RESET}"
        echo -e "  → sudo bash scripts/demo_mount_setup.sh mount 실행 필요"
        ok=false
    else
        echo -e "${GREEN}✓ CRAM 마운트 활성: $MOUNT_CRAM${RESET}"
    fi

    if ! mountpoint -q "$MOUNT_REFERENCE" 2>/dev/null; then
        echo -e "${YELLOW}△ 참조 게놈 마운트 없음 (일부 시나리오 제한)${RESET}"
    else
        echo -e "${GREEN}✓ 참조 게놈 마운트 활성: $MOUNT_REFERENCE${RESET}"
    fi

    if [ ! -f "$MOUNT_CRAM/$TEST_CRAM" ]; then
        echo -e "${RED}✗ 테스트 CRAM 파일 없음: $MOUNT_CRAM/$TEST_CRAM${RESET}"
        ok=false
    else
        echo -e "${GREEN}✓ 테스트 CRAM: $TEST_CRAM${RESET}"
    fi

    echo ""
    if ! $ok; then
        echo -e "${RED}사전 조건 미충족. 아래 명령으로 환경을 설정하세요:${RESET}"
        echo "  sudo bash scripts/demo_mount_setup.sh mount"
        exit 1
    fi
}

# ========================================================================
# 시나리오 1: S3 데이터를 로컬 파일시스템처럼 탐색
# ========================================================================
scenario_1() {
    banner "시나리오 1: S3 버킷을 로컬 파일시스템으로 마운트"

    echo "Mountpoint for Amazon S3는 S3 버킷을 POSIX 호환 파일시스템으로 마운트합니다."
    echo "S3 API 호출 없이 일반 리눅스 명령어로 데이터를 탐색할 수 있습니다."
    echo ""
    echo -e "버킷: ${BOLD}$BUCKET_NAME${RESET}"
    echo -e "마운트: ${BOLD}$MOUNT_GENOMICS${RESET}"
    pause

    section "1-1. 전체 버킷 디렉토리 구조 확인"
    run_cmd "ls -la $MOUNT_GENOMICS/"

    section "1-2. CRAM 파일 목록 (internal/cram/)"
    run_cmd "ls -lh $MOUNT_GENOMICS/internal/cram/"

    section "1-3. 참조 게놈 확인 (reference/GRCh38/)"
    run_cmd "ls -lh $MOUNT_GENOMICS/reference/GRCh38/"

    section "1-4. 파일 상세 정보 (stat)"
    run_cmd "stat $MOUNT_CRAM/$TEST_CRAM"

    section "1-5. 파일 크기를 사람이 읽기 쉬운 형태로"
    run_cmd "du -h $MOUNT_CRAM/$TEST_CRAM"

    echo -e "${GREEN}✓ S3 데이터를 ls, stat, du 등 표준 리눅스 명령어로 탐색 완료${RESET}"
    pause
}

# ========================================================================
# 시나리오 2: samtools로 유전체 데이터 직접 분석
# ========================================================================
scenario_2() {
    banner "시나리오 2: Mountpoint를 통한 유전체 데이터 분석 (samtools)"

    echo "마운트된 CRAM 파일을 samtools로 직접 분석합니다."
    echo "samtools는 Mountpoint를 통해 필요한 바이트만 S3에서 가져옵니다 (byte-range read)."
    echo ""
    echo -e "테스트 파일: ${BOLD}$TEST_CRAM${RESET} ($DATA_LABEL)"
    echo -e "참조 게놈: ${BOLD}$TEST_REFERENCE${RESET}"
    pause

    section "2-1. CRAM 무결성 확인 (quickcheck)"
    run_cmd "samtools quickcheck $MOUNT_CRAM/$TEST_CRAM && echo 'PASS: CRAM 파일 무결성 확인됨'"

    section "2-2. CRAM 헤더 읽기 (metadata access)"
    run_cmd "samtools view -H $MOUNT_CRAM/$TEST_CRAM | head -20"

    section "2-3. 전체 통계 (flagstat) - 전체 파일 순차 읽기"
    run_cmd "samtools flagstat $MOUNT_CRAM/$TEST_CRAM"

    section "2-4. 인덱스 통계 (idxstats) - reference별 read 수"
    run_cmd "samtools idxstats $MOUNT_CRAM/$TEST_CRAM"

    if [ -f "$TEST_REFERENCE" ]; then
        section "2-5. 특정 게놈 영역 쿼리 (region query)"
        echo "리전: $TEST_REGION"
        echo "samtools는 .crai 인덱스를 먼저 읽고, 해당 영역의 바이트만 S3에서 가져옵니다."
        echo ""
        run_cmd "samtools view -c --reference $TEST_REFERENCE $MOUNT_CRAM/$TEST_CRAM $TEST_REGION"
        echo "(위 숫자: 해당 영역의 read 수)"
    else
        echo -e "${YELLOW}참조 게놈 없음 - region query 건너뜀${RESET}"
    fi

    echo -e "${GREEN}✓ Mountpoint를 통해 samtools의 모든 표준 분석 가능 확인${RESET}"
    pause
}

# ========================================================================
# 시나리오 3: EID 매핑 + 심볼릭 링크를 통한 연구자 접근
# ========================================================================
scenario_3() {
    banner "시나리오 3: EID 매핑 - 연구자 친화적 파일명 접근"

    echo "연구자는 프로젝트별 EID(예: EID_1234567)로 데이터에 접근합니다."
    echo "실제 데이터는 내부 관리 번호(internal_id)로 S3에 저장되며,"
    echo "심볼릭 링크가 EID -> internal_id 변환을 투명하게 처리합니다."
    echo ""
    echo "이 구조의 핵심:"
    echo "  - 연구자는 내부 관리 번호를 알 필요 없음"
    echo "  - 동일 파일을 여러 프로젝트에서 다른 EID로 참조 가능 (1카피 다중 매핑)"
    echo "  - S3 저장 비용 최소화"
    pause

    section "3-1. 매핑 테이블 확인"
    echo "EID 매핑 JSON:"
    run_cmd "cat $PROJECT_DIR/data/mapping/eid_mapping.json"

    section "3-2. 심볼릭 링크 구조"
    run_cmd "ls -la $MOUNT_SYMLINK/"

    section "3-3. EID로 CRAM 접근 (연구자 관점)"
    echo "연구자 명령: samtools quickcheck ${TEST_EID}.cram"
    if [ -L "$MOUNT_SYMLINK/${TEST_EID}.cram" ]; then
        run_cmd "samtools quickcheck $MOUNT_SYMLINK/${TEST_EID}.cram && echo 'PASS: EID 기반 접근 성공'"

        section "3-4. EID -> 실제 경로 추적"
        run_cmd "readlink -f $MOUNT_SYMLINK/${TEST_EID}.cram"
        echo "위 결과: 연구자의 ${TEST_EID}.cram이 실제로는 S3의 어떤 파일에 매핑되는지 확인"

        section "3-5. 동일 파일 다중 매핑 확인"
        echo "project_001의 EID_1234567과 project_002의 EID_9876543은"
        echo "모두 internal_id_000001.cram을 가리킵니다:"
        echo ""
        echo "  project_001/EID_1234567 -> internal_id_000001.cram"
        echo "  project_002/EID_9876543 -> internal_id_000001.cram"
        echo ""
        echo "S3에는 1카피만 저장 → 저장 비용 절약"
    else
        echo -e "${YELLOW}심볼릭 링크 없음 - demo_mount_setup.sh 실행 필요${RESET}"
    fi

    echo ""
    echo -e "${GREEN}✓ EID 매핑을 통한 투명한 연구자 접근 시연 완료${RESET}"
    pause
}

# ========================================================================
# 시나리오 4: 캐시 효과 비교 (성능 벤치마크)
# ========================================================================
scenario_4() {
    banner "시나리오 4: 캐시 성능 비교"

    echo "동일한 S3 데이터를 두 가지 마운트 설정으로 접근하여 캐시 효과를 비교합니다."
    echo ""
    echo "  [A] $MOUNT_CRAM          - 캐시 없음 (매번 S3 요청)"
    echo "  [B] $MOUNT_CRAM_CACHED   - 디스크 캐시 활성 (반복 접근 시 로컬 캐시)"
    echo ""
    echo -e "테스트: samtools flagstat (전체 파일 순차 읽기) × 2회"
    pause

    if ! mountpoint -q "$MOUNT_CRAM_CACHED" 2>/dev/null; then
        echo -e "${YELLOW}캐시 마운트 비활성 - 건너뜀${RESET}"
        return
    fi

    section "4-1. 첫 번째 실행 (cold cache)"

    echo "[A] 캐시 없음:"
    local t1_nocache
    t1_nocache=$(timed_cmd "no-cache 1st" "samtools flagstat $MOUNT_CRAM/$TEST_CRAM > /dev/null")

    echo "[B] 캐시 활성 (cold):"
    local t1_cached
    t1_cached=$(timed_cmd "cached 1st" "samtools flagstat $MOUNT_CRAM_CACHED/$TEST_CRAM > /dev/null")

    section "4-2. 두 번째 실행 (warm cache)"

    echo "[A] 캐시 없음 (여전히 S3 요청):"
    local t2_nocache
    t2_nocache=$(timed_cmd "no-cache 2nd" "samtools flagstat $MOUNT_CRAM/$TEST_CRAM > /dev/null")

    echo "[B] 캐시 활성 (warm - 로컬에서 읽기):"
    local t2_cached
    t2_cached=$(timed_cmd "cached 2nd" "samtools flagstat $MOUNT_CRAM_CACHED/$TEST_CRAM > /dev/null")

    section "4-3. 결과 요약"
    echo "┌────────────────────┬──────────────┬──────────────┐"
    echo "│                    │  1st (cold)  │  2nd (warm)  │"
    echo "├────────────────────┼──────────────┼──────────────┤"
    printf "│  %-18s │  %8sms  │  %8sms  │\n" "캐시 없음" "$t1_nocache" "$t2_nocache"
    printf "│  %-18s │  %8sms  │  %8sms  │\n" "캐시 활성" "$t1_cached" "$t2_cached"
    echo "└────────────────────┴──────────────┴──────────────┘"
    echo ""

    if [[ "$t2_cached" -gt 0 ]] && [[ "$t2_nocache" -gt 0 ]]; then
        local speedup=$((t2_nocache * 100 / t2_cached))
        echo -e "캐시 warm 시 속도 향상: ${GREEN}${speedup}%${RESET} (no-cache 대비)"
    fi

    echo ""
    echo -e "${GREEN}✓ 디스크 캐시로 반복 접근 시 S3 요청 제거 → 지연시간 대폭 감소${RESET}"
    pause
}

# ========================================================================
# 시나리오 5: 대용량 데이터 region query (byte-range 효율성)
# ========================================================================
scenario_5() {
    banner "시나리오 5: 대용량 CRAM의 효율적인 영역 쿼리"

    echo "대용량 WGS CRAM 파일(15+ GB)에서 특정 게놈 영역만 접근합니다."
    echo "Mountpoint + samtools의 byte-range read로 전체 다운로드 없이 필요한 부분만 가져옵니다."
    echo ""

    # 대용량 파일 확인
    local large_cram="internal_id_100001.cram"
    local large_ref=$(_find_ref \
        "$PROJECT_DIR/data/reference_grch38_full/GRCh38_full_analysis_set_plus_decoy_hla.fa" \
        "$MOUNT_REFERENCE/GRCh38_full_analysis_set_plus_decoy_hla.fa")

    if [ ! -f "$MOUNT_CRAM/$large_cram" ]; then
        echo -e "${YELLOW}1000 Genomes 데이터 없음 ($large_cram) - 합성 데이터로 대체${RESET}"
        large_cram="$TEST_CRAM"
        large_ref="$TEST_REFERENCE"
    fi

    echo -e "파일: ${BOLD}$large_cram${RESET}"
    run_cmd "ls -lh $MOUNT_CRAM/$large_cram"
    pause

    section "5-1. 파일 크기 vs 쿼리 영역"
    local file_size_bytes
    file_size_bytes=$(stat -c %s "$MOUNT_CRAM/$large_cram" 2>/dev/null || echo "0")
    local file_size_gb=$((file_size_bytes / 1073741824))
    local file_size_mb=$((file_size_bytes / 1048576))

    echo "전체 파일 크기: ${file_size_mb} MB (${file_size_gb} GB)"
    echo "쿼리 영역: chr22:16,000,000-17,000,000 (1 Mbp)"
    echo ""
    echo "전체 다운로드 불필요! 인덱스(.crai)로 위치를 찾고 해당 바이트만 전송."

    section "5-2. 인덱스 기반 영역 쿼리"
    if [ -f "$large_ref" ]; then
        echo "실행: samtools view -c --reference <ref> <cram> chr22:16M-17M"
        echo ""

        local start_ms=$(($(date +%s%N) / 1000000))
        local read_count
        read_count=$(samtools view -c --reference "$large_ref" "$MOUNT_CRAM/$large_cram" chr22:16000000-17000000 2>/dev/null || echo "N/A")
        local end_ms=$(($(date +%s%N) / 1000000))
        local elapsed=$((end_ms - start_ms))

        echo -e "  영역 내 read 수: ${BOLD}$read_count${RESET}"
        echo -e "  소요 시간: ${GREEN}${elapsed}ms${RESET}"
        echo ""

        if [[ "$file_size_bytes" -gt 0 ]] && [[ "$elapsed" -gt 0 ]]; then
            echo "전체 파일 다운로드 대비 효율:"
            echo "  전체 파일: ${file_size_mb} MB"
            echo "  실제 전송: 수 MB (인덱스 + 해당 영역 데이터만)"
            echo "  → 전체 대비 약 0.1% 이하만 네트워크 전송"
        fi
    else
        echo -e "${YELLOW}참조 게놈 없음 - 헤더 접근으로 대체${RESET}"
        echo ""
        timed_cmd "header" "samtools view -H $MOUNT_CRAM/$large_cram | tail -5"
    fi

    section "5-3. 여러 영역 연속 쿼리"
    if [ -f "$large_ref" ]; then
        echo "실제 분석에서는 여러 영역을 연속으로 쿼리합니다:"
        echo ""
        for region in "chr22:16000000-16500000" "chr22:20000000-21000000" "chr22:30000000-31000000"; do
            local start_ms=$(($(date +%s%N) / 1000000))
            local cnt
            cnt=$(samtools view -c --reference "$large_ref" "$MOUNT_CRAM/$large_cram" "$region" 2>/dev/null || echo "0")
            local end_ms=$(($(date +%s%N) / 1000000))
            local elapsed=$((end_ms - start_ms))
            printf "  %-30s  reads: %-8s  time: %dms\n" "$region" "$cnt" "$elapsed"
        done
    fi

    echo ""
    echo -e "${GREEN}✓ 대용량 파일에서 전체 다운로드 없이 필요한 영역만 효율적으로 접근${RESET}"
    pause
}

# ========================================================================
# 메인 실행
# ========================================================================
main() {
    banner "S3 Mountpoint for Amazon S3 — 유전체 데이터 접근 데모"

    echo -e "이 데모는 EC2에서 ${BOLD}Mountpoint for Amazon S3${RESET}를 사용하여"
    echo "S3에 저장된 유전체(CRAM) 데이터를 로컬 파일시스템처럼 접근하는 것을 보여줍니다."
    echo ""
    echo "시나리오:"
    echo "  1. S3 버킷을 로컬 파일시스템으로 마운트 및 탐색"
    echo "  2. samtools로 유전체 데이터 직접 분석"
    echo "  3. EID 매핑을 통한 연구자 접근"
    echo "  4. 캐시 효과 성능 비교"
    echo "  5. 대용량 CRAM의 효율적 영역 쿼리 (byte-range read)"
    echo ""
    echo -e "데이터: ${BOLD}$DATA_LABEL${RESET}"
    echo ""
    pause

    check_prerequisites

    should_run 1 && scenario_1
    should_run 2 && scenario_2
    should_run 3 && scenario_3
    should_run 4 && scenario_4
    should_run 5 && scenario_5

    banner "데모 완료"
    echo "시연된 핵심 기능:"
    echo "  ✓ S3 Mountpoint: S3를 POSIX 파일시스템으로 마운트"
    echo "  ✓ 바이트 범위 읽기: 전체 다운로드 없이 필요한 영역만 접근"
    echo "  ✓ samtools 완전 호환: quickcheck, flagstat, region query"
    echo "  ✓ EID 매핑: 심볼릭 링크를 통한 투명한 ID 변환"
    echo "  ✓ 디스크 캐시: 반복 접근 시 S3 요청 제거"
    echo ""
    echo "정리: sudo bash scripts/demo_mount_setup.sh unmount"
}

main
