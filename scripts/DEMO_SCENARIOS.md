# S3 Mountpoint 유전체 데이터 접근 데모 시나리오

## 데모 개요

EC2에서 **Mountpoint for Amazon S3**를 사용하여 S3에 저장된 WGS CRAM 파일을 로컬 파일시스템처럼 접근하는 것을 시연합니다. UK Biobank RAP의 dxfuse 아키텍처를 AWS 네이티브 서비스로 대체할 수 있음을 보여줍니다.

## 사전 준비

```bash
# 1. 데모 마운트 설정 (sudo 필요)
sudo bash scripts/demo_mount_setup.sh mount

# 2. 상태 확인
sudo bash scripts/demo_mount_setup.sh status

# 3. 데모 실행
bash scripts/demo_mountpoint.sh              # 대화형 (Enter로 진행)
bash scripts/demo_mountpoint.sh --auto       # 자동 진행
bash scripts/demo_mountpoint.sh --scenario 2 # 특정 시나리오만
bash scripts/demo_mountpoint.sh --1kg        # 1000 Genomes 대용량 데이터 사용
```

## 마운트 포인트 구성

| 마운트 포인트 | S3 Prefix | 캐시 | 용도 |
|---|---|---|---|
| `/mnt/demo-genomics` | (전체 버킷) | 없음 | 버킷 구조 탐색 |
| `/mnt/demo-cram` | `internal/cram/` | 없음 | 순수 S3 성능 측정 |
| `/mnt/demo-cram-cached` | `internal/cram/` | 디스크 캐시 | 캐시 효과 비교 |
| `/mnt/demo-reference` | `reference/GRCh38/` | 디스크 캐시 | 참조 게놈 (변경 없는 데이터) |
| `/mnt/demo-symlink` | - | - | EID 심볼릭 링크 레이어 |

---

## 시나리오 1: S3 버킷을 로컬 파일시스템으로 마운트

**핵심 메시지**: S3 API 호출 없이 `ls`, `stat` 등 표준 리눅스 명령어로 데이터 탐색 가능

**시연 내용**:
- 전체 버킷을 마운트하여 디렉토리 구조 탐색
- CRAM 파일 목록 및 크기 확인
- 참조 게놈 확인
- `stat`으로 파일 메타데이터 확인

**핵심 명령어**:
```bash
ls -lh /mnt/demo-genomics/                        # S3 버킷 전체 구조
ls -lh /mnt/demo-genomics/internal/cram/           # CRAM 파일 목록
stat /mnt/demo-cram/internal_id_000001.cram        # 파일 상세 정보
```

**발표 포인트**:
- Mountpoint는 Rust로 작성된 커널 레벨 FUSE 드라이버 (고성능)
- `--read-only` 모드로 데이터 안전성 보장
- `--prefix` 옵션으로 특정 S3 경로만 노출 가능 → 접근 제어

---

## 시나리오 2: samtools로 유전체 데이터 직접 분석

**핵심 메시지**: 마운트된 CRAM을 samtools로 직접 분석. 바이트 범위 읽기로 필요한 부분만 S3에서 전송

**시연 내용**:
1. `samtools quickcheck` — 무결성 확인 (파일 앞/뒤 몇 바이트만 읽음)
2. `samtools view -H` — 헤더 읽기 (파일 앞부분만)
3. `samtools flagstat` — 전체 통계 (순차 전체 읽기)
4. `samtools idxstats` — 인덱스 통계 (인덱스 파일만 읽기)
5. `samtools view -c <region>` — 특정 영역 쿼리 (인덱스 + 해당 바이트만)

**핵심 명령어**:
```bash
samtools quickcheck /mnt/demo-cram/internal_id_000001.cram
samtools view -H /mnt/demo-cram/internal_id_000001.cram | head -20
samtools flagstat /mnt/demo-cram/internal_id_000001.cram
samtools view -c --reference data/reference/GRCh38_chr22.fa \
    /mnt/demo-cram/internal_id_000001.cram chr22:16000000-17000000
```

**발표 포인트**:
- samtools는 Mountpoint를 통해 표준 POSIX `read()` 시스템 콜 사용
- Mountpoint가 내부적으로 S3 GetObject with Range 헤더로 변환
- 기존 바이오인포매틱스 파이프라인 변경 없이 사용 가능

---

## 시나리오 3: EID 매핑 — 연구자 친화적 파일명 접근

**핵심 메시지**: 연구자는 내부 관리 번호를 모름. EID로 접근하면 심볼릭 링크가 투명하게 변환

**시연 내용**:
1. EID 매핑 JSON 확인
2. 심볼릭 링크 구조 확인
3. EID로 CRAM 접근 (`samtools quickcheck EID_1234567.cram`)
4. `readlink -f`로 실제 경로 추적
5. 1카피 다중 매핑 개념 설명

**핵심 명령어**:
```bash
cat data/mapping/eid_mapping.json
ls -la /mnt/demo-symlink/
samtools quickcheck /mnt/demo-symlink/EID_1234567.cram
readlink -f /mnt/demo-symlink/EID_1234567.cram
```

**발표 포인트**:
- **1카피 다중 매핑**: `internal_id_000001.cram`이 project_001에서는 `EID_1234567`, project_002에서는 `EID_9876543`으로 노출
- 1,000명 연구자가 동일 파일에 접근해도 S3에는 1카피만 존재
- 프로젝트별 접근 권한을 Cognito + IAM으로 제어 가능

---

## 시나리오 4: 캐시 효과 성능 비교

**핵심 메시지**: Mountpoint 디스크 캐시로 반복 접근 시 S3 요청 제거, 지연시간 대폭 감소

**시연 내용**:
1. 캐시 없는 마운트 vs 캐시 있는 마운트로 `flagstat` 2회 실행
2. 1st run (cold cache): 양쪽 모두 S3에서 가져옴
3. 2nd run (warm cache): 캐시 마운트는 로컬에서 읽기
4. 결과 테이블 비교

**핵심 명령어**:
```bash
# 캐시 없음
time samtools flagstat /mnt/demo-cram/internal_id_000001.cram > /dev/null

# 캐시 있음 (warm)
time samtools flagstat /mnt/demo-cram-cached/internal_id_000001.cram > /dev/null
```

**발표 포인트**:
- Mountpoint의 `--cache` 옵션은 로컬 SSD에 데이터 캐시
- 동일 파일에 여러 samtools 작업(quickcheck → flagstat → view)을 할 때 효과적
- `--metadata-ttl` 설정으로 메타데이터 캐시 기간 제어 (참조 게놈은 `indefinite`)

---

## 시나리오 5: 대용량 CRAM의 효율적 영역 쿼리

**핵심 메시지**: 15GB CRAM에서 1Mbp 영역만 쿼리 → 전체의 0.1% 이하만 네트워크 전송

**시연 내용**:
1. 1000 Genomes CRAM 파일 크기 확인 (15.9 GB)
2. 특정 영역(chr22:16M-17M) 쿼리 및 소요 시간 측정
3. 여러 영역 연속 쿼리 (실제 분석 패턴)

**핵심 명령어** (`--1kg` 플래그 사용):
```bash
ls -lh /mnt/demo-cram/internal_id_100001.cram    # 15.9 GB
samtools view -c --reference <full_ref> \
    /mnt/demo-cram/internal_id_100001.cram chr22:16000000-17000000
```

**발표 포인트**:
- CRAM 인덱스(.crai)로 영역 위치 결정 → 해당 바이트만 S3 Range 요청
- 15GB 파일에서 수 MB만 전송 → 네트워크 효율 극대화
- UK Biobank 시나리오: 500,000 샘플 × 30GB/샘플 = 15 PB → 이 방식이 아니면 접근 불가
- dxfuse와 동일한 byte-range read 원리, AWS 네이티브 서비스로 구현

---

## 정리 명령어

```bash
# 마운트 해제
sudo bash scripts/demo_mount_setup.sh unmount

# 기존 테스트용 마운트 복원 (필요 시)
sudo bash scripts/04_mount_s3.sh mount
```

## 데모 데이터 요약

| 데이터 | 소스 | 크기 | 용도 |
|---|---|---|---|
| `internal_id_000001~3.cram` | 합성 (wgsim) | 3.3 MB × 3 | 빠른 시연 |
| `internal_id_100001.cram` | HG00096 (1000 Genomes) | 15.9 GB | 실제 크기 시연 |
| `internal_id_100002.cram` | NA06985 (1000 Genomes) | 15.5 GB | 추가 샘플 |
| `internal_id_100003.cram` | NA06986 (1000 Genomes) | 15.9 GB | 추가 샘플 |
| `GRCh38_chr22.fa` | UCSC | 49.4 MB | 합성 데이터용 참조 |
| `GRCh38_full_*.fa` | 1000 Genomes | 3.0 GB | 실제 데이터용 참조 |
