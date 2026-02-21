# CRAM + AWS Mountpoint S3 PoC 결과 보고서

**작성일**: 2026-02-20
**환경**: Amazon Linux 2023 (EC2, ap-northeast-2), Account <YOUR_ACCOUNT_ID>
**목적**: UK Biobank RAP의 dxfuse 기반 CRAM 파일 접근 아키텍처를 AWS 환경에서 재현하고, 3가지 접근법의 기능성과 성능을 비교 검증

---

## 1. 배경

UK Biobank Research Analysis Platform(RAP)은 DNAnexus의 dxfuse를 사용하여 대용량 WGS CRAM 파일(>5GB/파일)을 연구자에게 제공한다. 핵심 메커니즘은 다음과 같다:

- **EID 매핑**: 연구자는 프로젝트별 7자리 EID(`EID_7654321.cram`)로 파일에 접근하지만, 실제 데이터는 내부 관리 번호(`internal_id_999.cram`)로 중앙 저장소에 단일 카피로 존재
- **FUSE 마운트**: `dx mount` -> `/mnt/project`로 클라우드 스토리지를 로컬 파일시스템처럼 마운트
- **온디맨드 바이트 범위 읽기**: samtools가 CRAM의 특정 영역만 요청하면 FUSE가 해당 바이트 범위만 HTTP Range 요청으로 가져옴
- **저장 효율**: 1,000명의 연구자가 동일 파일에 접근해도 S3에는 1카피만 존재

그러나 dxfuse는 메모리 오버헤드(OOM), Cloud Workstation 불안정성 등의 한계가 보고되어 있다. 이 PoC는 AWS 네이티브 서비스(Mountpoint S3, S3 API)를 활용하여 동일한 아키텍처를 재현하고 대안을 비교한다.

---

## 2. 아키텍처

### 2.1 전체 구성

```
연구자 워크스테이션
│
│  samtools view EID_1234567.cram chr22:16M-17M
│
├─ [Approach A] /mnt/project (Custom FUSE: eid_fuse.py)
│     │
│     ├── SQLite Metadata DB ── EID_1234567 -> inode -> s3_key
│     ├── Prefetch Engine ───── 순차 접근 감지 -> 비동기 선행 읽기
│     └── S3 GetObject ──────── Range: bytes=X-Y
│
├─ [Approach B] /mnt/project-symlink (Symlink Layer)
│     │
│     └── EID_1234567.cram -> /mnt/s3-internal/internal_id_000001.cram
│                                    │
│                                    └── Mountpoint S3 (커널 FUSE + 캐시)
│
├─ [Approach C] htslib S3 Plugin (FUSE 없이 직접 접근)
│     │
│     └── samtools -> s3://bucket/internal/cram/internal_id_000001.cram
│
▼
Amazon S3: <YOUR_BUCKET_NAME>
├── internal/cram/          ← CRAM 마스터 데이터 (internal_id)
├── reference/GRCh38/       ← 참조 게놈
└── metadata/eid_mapping/   ← EID 매핑 JSON
```

### 2.2 dxfuse vs eid_fuse.py 아키텍처 대응

| dxfuse (Go) | eid_fuse.py (Python) | 역할 |
|---|---|---|
| `metadata_db.go` SQLite 3테이블 | SQLite shared-memory DB 3테이블 | inode -> 파일 메타데이터, path -> inode 해석 |
| `dxfuse.go` FileHandle + fhTable | `file_handles` dict | 열린 파일 상태 (presigned URL 포함) |
| `dx_ops.go` DxDownloadURL | S3 presigned URL 생성 | 파일 다운로드 URL 발급 |
| `prefetch.go` 상태머신 (NIL->DETECT_SEQ->PREFETCH->EOF) | `PrefetchManager` + `PrefetchFileState` | 순차 접근 감지 + 비동기 선행 읽기 |
| `dx_describe.go` BulkDescribe | S3 HeadObject | 파일 메타데이터 일괄 조회 |
| HTTP Range 요청 | S3 GetObject with Range header | 바이트 범위 읽기 |

### 2.3 SQLite 스키마 (dxfuse 동일 구조)

```sql
CREATE TABLE data_objects (
    inode INTEGER PRIMARY KEY,
    s3_key TEXT NOT NULL,      -- internal/cram/internal_id_XXXXXX.cram
    eid TEXT NOT NULL,         -- EID_XXXXXXX
    size INTEGER, mtime REAL, ctime REAL
);
CREATE TABLE namespace (
    parent TEXT NOT NULL,
    name TEXT NOT NULL,        -- EID_XXXXXXX.cram (연구자가 보는 파일명)
    obj_type INTEGER,          -- 1=directory, 2=file
    inode INTEGER,
    PRIMARY KEY (parent, name)
);
CREATE TABLE directories (
    inode INTEGER PRIMARY KEY,
    populated INTEGER DEFAULT 0, mtime REAL
);
```

---

## 3. 구현 상세

### 3.1 설치된 도구

| 도구 | 버전 | 설치 방법 |
|---|---|---|
| samtools | 1.21 | 소스 빌드 (`--enable-s3 --enable-libcurl`) |
| htslib | 1.21 | 소스 빌드 (S3 플러그인 활성화) |
| mount-s3 | 1.22.0 | RPM 패키지 |
| fusepy | latest | pip3 |
| boto3 | pre-installed | IAM Role 인증 |

### 3.2 테스트 데이터

| 항목 | 상세 |
|---|---|
| 참조 게놈 | GRCh38 chr22 (50,818,468 bp, 49.4 MiB) |
| 샘플 수 | 3개 (wgsim 합성) |
| Reads/샘플 | 100,000 paired-end (200,000 total reads) |
| CRAM 크기/샘플 | ~3.3 MiB |
| Read 길이 | 150bp |
| Mapping | 100% mapped, 100% properly paired |

### 3.3 S3 버킷 구조

```
s3://<YOUR_BUCKET_NAME>/          총 59.3 MiB
├── internal/cram/
│   ├── internal_id_000001.cram      (3.3 MiB)  + .crai
│   ├── internal_id_000002.cram      (3.3 MiB)  + .crai
│   └── internal_id_000003.cram      (3.3 MiB)  + .crai
├── reference/GRCh38/
│   ├── GRCh38_chr22.fa              (49.4 MiB)
│   └── GRCh38_chr22.fa.fai
└── metadata/eid_mapping/
    └── eid_mapping.json
```

### 3.4 EID 매핑 구성

```json
{
  "project_001": {
    "EID_1234567": "internal_id_000001",
    "EID_2345678": "internal_id_000002",
    "EID_3456789": "internal_id_000003"
  },
  "project_002": {
    "EID_9876543": "internal_id_000001",
    "EID_8765432": "internal_id_000002"
  }
}
```

동일한 `internal_id_000001`이 project_001에서는 `EID_1234567`, project_002에서는 `EID_9876543`으로 노출되어 **1카피 다중 매핑**을 검증함.

### 3.5 마운트 포인트

| 마운트 포인트 | 타입 | 백엔드 |
|---|---|---|
| `/mnt/s3-internal` | Mountpoint S3 | `s3://bucket/internal/cram/` |
| `/mnt/s3-reference` | Mountpoint S3 | `s3://bucket/reference/GRCh38/` |
| `/mnt/project` | Custom FUSE (eid_fuse.py) | S3 직접 접근 (boto3) |
| `/mnt/project-symlink` | Symlink -> Mountpoint S3 | `/mnt/s3-internal/` |

---

## 4. 기능 테스트 결과

### 4.1 전체 결과: 17/17 PASS

```
=== Local Baseline ===
  PASS: samtools quickcheck OK
  PASS: Header contains @HD
  PASS: flagstat: 200000 + 0 in total
  PASS: Region query returned 382 reads (chr22:1-100000)

=== Approach A: Custom FUSE (eid_fuse.py) ===
  PASS: ls shows EID files
  PASS: samtools quickcheck OK
  PASS: Header contains @HD
  PASS: Region query returned 382 reads (chr22:1-100000)
  PASS: flagstat: 200000 + 0 in total
  PASS: CRAI index file exists

=== Approach B: Symlink Layer ===
  PASS: Symlink resolves to correct internal ID
  PASS: CRAM accessible through symlink
  PASS: samtools quickcheck OK
  PASS: Header contains @HD
  PASS: Region query returned 382 reads (chr22:1-100000)

=== Approach C: htslib S3 Plugin ===
  PASS: EID resolves to samtools command
  PASS: Header retrieved via S3 plugin
```

### 4.2 EID 변환 검증

| 접근 경로 | 명령 | 결과 |
|---|---|---|
| Custom FUSE | `ls /mnt/project/` | `EID_1234567.cram` 등 6개 파일 표시 (CRAM + CRAI) |
| Custom FUSE | `samtools view -H /mnt/project/EID_1234567.cram` | `@RG ID:internal_id_000001` 확인 (올바른 매핑) |
| Symlink | `readlink /mnt/project-symlink/EID_1234567.cram` | `/mnt/s3-internal/internal_id_000001.cram` |
| S3 Plugin | `cram_access.py EID_1234567 --dry-run` | `samtools view s3://...internal_id_000001.cram` |

### 4.3 핵심 동작 검증

```bash
# 연구자 관점: EID로 접근
$ samtools view /mnt/project/EID_1234567.cram chr22:16000000-16100000 | wc -l
398

# 내부 동작: S3에서 바이트 범위 읽기 (eid_fuse.py 로그)
# EID_1234567 -> namespace -> inode 3 -> s3_key: internal/cram/internal_id_000001.cram
# S3 GetObject Range: bytes=0-3458782
```

---

## 5. 성능 벤치마크 결과

### 5.1 측정 조건

- **반복**: 3회, 중앙값(median) 보고
- **대상 파일**: `EID_1234567.cram` (3.3 MiB, 200K reads)
- **참조 게놈**: 로컬 GRCh38 chr22 (50 MiB)
- **네트워크**: EC2 인스턴스 -> S3 (동일 리전 ap-northeast-2)

### 5.2 결과 표

| 테스트 | Local (기준선) | Approach A (Custom FUSE) | Approach B (Symlink+Mountpoint) | Approach C (htslib S3) |
|---|---:|---:|---:|---:|
| **헤더 읽기** | 3 ms | 35 ms | 5 ms | 841 ms |
| **영역 읽기** (chr22:1-100000) | 5 ms | 92 ms | 7 ms | 864 ms |
| **전체 파일 flagstat** | 27 ms | 416 ms | 31 ms | 888 ms |

### 5.3 상대 성능 비교 (Local = 1.0x)

| 테스트 | Local | FUSE (A) | Symlink (B) | S3 Plugin (C) |
|---|---:|---:|---:|---:|
| 헤더 읽기 | 1.0x | 11.7x | 1.7x | 280x |
| 영역 읽기 | 1.0x | 18.4x | 1.4x | 173x |
| 전체 파일 | 1.0x | 15.4x | 1.1x | 32.9x |

### 5.4 분석

**Approach B (Symlink + Mountpoint S3)가 가장 빠르다:**
- 로컬 대비 1.1~1.7x 오버헤드로, Mountpoint S3의 커널 수준 FUSE 구현과 로컬 파일 캐시(`/tmp/mountpoint-cache`)가 핵심
- 첫 번째 접근 후 캐시가 warm되면 사실상 로컬 파일 읽기와 동등한 성능
- Rust로 작성된 mount-s3는 Python FUSE 대비 시스템콜 오버헤드가 극히 낮음

**Approach A (Custom FUSE)는 아키텍처 재현에 충실하지만 Python 오버헤드 존재:**
- Python fusepy의 유저스페이스 -> 커널 -> 유저스페이스 왕복(context switch) 비용
- 매 read()마다 boto3 S3 API 호출 (HTTP 연결 오버헤드)
- 프리페치 엔진이 순차 읽기에서는 효과적이나, 소형 파일에서는 감지 시간이 상대적으로 큼
- Go 또는 Rust로 재작성 시 Approach B 수준으로 성능 향상 가능

**Approach C (htslib S3 Plugin)가 가장 느린 이유:**
- Python 래퍼(`cram_access.py`) -> samtools 프로세스 fork 오버헤드 (~700ms)
- 매 호출마다 S3 연결 새로 수립 (connection reuse 없음)
- FUSE 메모리 오버헤드가 전혀 없다는 장점이 있으나, 인터랙티브 사용에는 부적합

---

## 6. 바이트 범위 정합성 검증

### 6.1 결과: 9/9 PASS (4개 소스 MD5 일치)

| 테스트 | 오프셋 | 크기 | Local MD5 | FUSE MD5 | Symlink MD5 | S3 Direct MD5 |
|---|---:|---:|---|---|---|---|
| CRAM magic | 0 | 26B | c6cf3a64 | c6cf3a64 | c6cf3a64 | c6cf3a64 |
| First 4KB | 0 | 4,096B | 68b76ec6 | 68b76ec6 | 68b76ec6 | 68b76ec6 |
| Middle 4KB | 1,729,391 | 4,096B | fa6cea28 | fa6cea28 | fa6cea28 | fa6cea28 |
| Last 4KB | 3,454,687 | 4,096B | 7afd442c | 7afd442c | 7afd442c | 7afd442c |
| CRAM EOF marker | 3,458,745 | 38B | a4d9dc2f | a4d9dc2f | a4d9dc2f | a4d9dc2f |
| First 1MB | 0 | 1,048,576B | 62b43397 | 62b43397 | 62b43397 | 62b43397 |
| Random #1 | 2,681,950 | 8,192B | 9934b64d | 9934b64d | 9934b64d | 9934b64d |
| Random #2 | 466,956 | 8,192B | d99cff80 | d99cff80 | d99cff80 | d99cff80 |
| Random #3 | 104,902 | 8,192B | d3624f17 | d3624f17 | d3624f17 | d3624f17 |

모든 접근 경로에서 동일 오프셋의 바이트 데이터가 bit-for-bit 일치함을 확인했다. 이는 CRAM 파일의 슬라이스 디코딩 정확성을 보장하는 핵심 요건이다.

---

## 7. 접근법 비교 종합

| 평가 항목 | Approach A (Custom FUSE) | Approach B (Symlink+Mountpoint) | Approach C (htslib S3) |
|---|---|---|---|
| **dxfuse 아키텍처 유사도** | 높음 (SQLite, 프리페치, FileHandle) | 낮음 (단순 심볼릭 링크) | 낮음 (FUSE 없음) |
| **성능** | 중간 (35~416ms) | 최고 (5~31ms, 로컬급) | 낮음 (841~888ms) |
| **메모리 오버헤드** | 중간 (Python + SQLite) | 낮음 (mount-s3 Rust) | 없음 |
| **투명성** | 완전 (파일시스템 수준) | 완전 (심볼릭 링크) | 부분적 (래퍼 필요) |
| **EID 동적 변환** | 실시간 (SQLite lookup) | 정적 (symlink 재생성 필요) | 실시간 (Python 래퍼) |
| **확장성** | DynamoDB로 확장 가능 | 수만 심볼릭 링크 관리 부담 | 제한 없음 |
| **도입 복잡도** | 높음 (FUSE 데몬 운영) | 낮음 (mount-s3 + 스크립트) | 낮음 (Python 스크립트) |
| **장애 복원** | FUSE 프로세스 관리 필요 | mount-s3 자동 재마운트 | stateless |

---

## 8. 프로덕션 확장 제안

### 8.1 권장 아키텍처: Approach B 기반 + 동적 EID 매핑

프로덕션에서는 **Approach B의 성능**과 **Approach A의 동적 매핑**을 결합한 하이브리드 구조를 권장한다:

```
연구자 로그인 (Cognito User Pool)
    │
    ▼
Cognito 인증 + 프로젝트 그룹 확인      ← User Pool Group = 프로젝트 ID
    │
    ▼
Identity Pool: 프로젝트별 IAM Role 발급 ← Group → IAM Role 매핑
    │
    ▼
Lambda: EID 매핑 생성                   ← DynamoDB에서 프로젝트별 매핑 조회
    │
    ▼
Mountpoint S3 마운트                    ← 내부 CRAM 데이터 접근
    │
    ▼
Symlink 자동 생성 (EID -> Mountpoint)   ← Lambda 결과 기반
    │
    ▼
/mnt/project/EID_XXXXXXX.cram 접근 가능
```

**외부 연구자 인증에 Cognito를 선택한 이유**: IAM Identity Center는 조직 내부(workforce) 사용자 관리에 최적화되어 있으나, 다수의 외부 연구자(수백~수천 명)에게 프로젝트별 세분화된 접근 권한을 부여하는 시나리오에서는 Cognito가 적합하다. Cognito User Pool은 자체 회원가입/인증, MFA, 이메일 검증을 제공하며, User Pool Group을 프로젝트 단위로 구성하여 Identity Pool을 통해 프로젝트별 IAM Role을 동적으로 매핑할 수 있다.

### 8.2 핵심 AWS 서비스 매핑

| 역할 | PoC 구현 | 프로덕션 확장 |
|---|---|---|
| EID 매핑 DB | `eid_mapping.json` (정적) | **DynamoDB** (글로벌 테이블, 다중 인스턴스 공유) |
| 세션 초기화 | 수동 스크립트 | **Lambda** (세션 시작 시 EID symlink 자동 생성) |
| CRAM 스토리지 | S3 Standard | **S3 Intelligent-Tiering** (접근 빈도 기반 자동 계층화) |
| 파일시스템 | mount-s3 + symlink | **Mountpoint S3** (프로덕션 운영 검증됨) |
| 암호화 | 미적용 | **S3-SSE-KMS** (고객 관리 키) |
| 감사 로그 | 미적용 | **CloudTrail** + **S3 서버 접근 로그** |
| 인증 | IAM Role | **Cognito User Pool + Identity Pool** (프로젝트 그룹별 IAM Role 매핑) |

### 8.3 추가 다음 단계

1. **동시 접근 테스트**: 다수 프로세스가 동시에 서로 다른 EID를 읽는 시나리오
2. **Go/Rust FUSE 재작성**: eid_fuse.py의 Python 오버헤드를 제거하여 Approach A 성능을 B 수준으로 향상
3. **비용 분석**: S3 GET 요청 수/데이터 전송량 기반 비용 산출 → **Section 12에서 완료**
4. **전체 게놈 flagstat**: 17 GiB 파일 전체 순차 읽기 성능 비교

---

## 9. 1000 Genomes 실전 데이터 검증

### 9.1 테스트 데이터

| 샘플 | 유형 | CRAM 크기 | 소스 |
|---|---|---:|---|
| NA06985 (EID_4001001) | High-coverage WGS 30x | 16.4 GiB | 1000G_2504_high_coverage |
| NA06986 (EID_4001002) | High-coverage WGS 30x | 14.5 GiB | 1000G_2504_high_coverage |
| HG00096 (EID_4001003) | Low-coverage WGS 4x | 14.8 GiB | 1000genomes/data |

- **참조 게놈**: GRCh38 full analysis set + decoy + HLA (3.1 GiB, 3,366 contigs)
- **총 테스트 데이터**: 45.7 GiB (S3에 내부 ID로 저장, EID로 매핑)

### 9.2 기능 테스트 결과: 10/10 PASS

```
=== Approach B: Symlink + Mountpoint S3 ===
  PASS: Symlink resolves to correct internal ID
  PASS: CRAM accessible through symlink
  PASS: samtools quickcheck OK
  PASS: Header contains @HD
  PASS: Region query returned 25,083 reads (chr22:16M-16.1M)

=== Approach A: Custom FUSE (eid_fuse.py) ===
  PASS: ls shows EID files
  PASS: samtools quickcheck OK
  PASS: Header contains @HD
  PASS: Region query returned 25,083 reads (chr22:16M-16.1M)
  PASS: Cross-approach read count consistency (25,083)
```

### 9.3 성능 벤치마크 (16.4 GiB 실전 CRAM)

| 테스트 | Approach A (Custom FUSE) | Approach B (Symlink+Mountpoint) | Approach C (htslib S3) |
|---|---:|---:|---:|
| **헤더 읽기** | 80 ms | 18 ms | 622 ms |
| **영역 읽기** (chr22:16M-16.1M, 25K reads) | 508 ms | 56 ms | 1,301 ms |

#### 상대 성능 비교 (Symlink = 1.0x)

| 테스트 | Symlink (B) | FUSE (A) | S3 Plugin (C) |
|---|---:|---:|---:|
| 헤더 읽기 | 1.0x | 4.4x | 34.6x |
| 영역 읽기 | 1.0x | 9.1x | 23.2x |

### 9.4 합성 데이터 vs 실전 데이터 성능 비교

| 테스트 | 합성 (3.3 MiB) B/A 비율 | 실전 (16.4 GiB) B/A 비율 | 변화 |
|---|---:|---:|---|
| 헤더 읽기 | 7.0x | 4.4x | 대형 파일에서 FUSE 오버헤드 상대적 감소 |
| 영역 읽기 | 13.1x | 9.1x | 바이트 범위 읽기가 파일 크기에 덜 의존 |

**분석**: 실전 대용량 파일에서 Custom FUSE의 상대적 성능 저하가 합성 데이터 대비 개선되었다. 이는 초기 연결 오버헤드가 대형 파일에서 상대적으로 작아지기 때문이며, 프리페치 엔진의 순차 읽기 최적화도 대형 파일에서 더 효과적으로 작동함을 시사한다.

### 9.5 바이트 범위 정합성 검증: 9/9 PASS

16.4 GiB 파일의 다양한 오프셋에서 3개 소스(FUSE, Symlink, S3 Direct) 간 bit-for-bit 일치 확인:

| 테스트 | 오프셋 | 크기 | MD5 (3소스 일치) |
|---|---:|---:|---|
| CRAM magic | 0 | 26B | 7b6ef75f |
| First 4KB | 0 | 4,096B | ab727ab3 |
| 1MB offset | 1,048,576 | 4,096B | 0942d5b2 |
| 100MB offset | 104,857,600 | 4,096B | 9a76ffd0 |
| 1GB offset | 1,073,741,824 | 8,192B | 39caa53f |
| 5GB offset | 5,368,709,120 | 8,192B | 9f87a066 |
| 10GB offset | 10,737,418,240 | 8,192B | b9a2525f |
| 15GB offset | 16,106,127,360 | 8,192B | b03fb28d |
| CRAM EOF marker | 17,567,630,631 | 38B | a4d9dc2f |

10GB, 15GB 오프셋에서도 바이트 범위 읽기가 정확하게 동작하며, 이는 대용량 CRAM 파일의 임의 슬라이스 디코딩이 모든 접근 경로에서 동일하게 작동함을 증명한다.

---

## 10. CDK 인프라 구현

Section 8에서 제안한 프로덕션 아키텍처를 AWS CDK (TypeScript)로 구현하여 배포 완료하였다.

### 10.1 배포된 스택 구조

```
NetworkStack (VPC, Subnet, NAT, VPC Endpoint)
    │
    ├── StorageStack (S3, KMS, CloudTrail)
    ├── DatabaseStack (DynamoDB)
    └── AuthStack (Cognito User Pool + Identity Pool)
            │
            └── ComputeStack (Lambda ×3, EC2 워크스테이션)
```

### 10.2 배포된 리소스

| 리소스 | 식별자 |
|--------|--------|
| VPC | vpc-0f1940f2552786938 |
| S3 Data Bucket | genomics-data-<YOUR_ACCOUNT_ID> |
| KMS Key | 4b88e4e4-4a38-4981-aeb5-376dc2de8a15 |
| DynamoDB Table | genomics-eid-mapping |
| Cognito User Pool | ap-northeast-2_SYYQ4XmYu |
| Identity Pool | ap-northeast-2:e4bd0cd0-041a-4eb7-889f-200fd5908e1f |
| EC2 Workstation | i-0a3bc72e77aea8a2f |
| Lambda: eid-resolver | genomics-eid-resolver |
| Lambda: session-init | genomics-session-init |
| Lambda: data-seeder | genomics-data-seeder |
| CloudTrail | genomics-data-trail |

### 10.3 End-to-End 검증 결과

1. **DynamoDB 시딩**: data-seeder Lambda로 4개 프로젝트, 10개 EID 매핑 입력 완료
2. **EID 해석**: eid-resolver Lambda 호출 → `project_001/EID_1234567` → `internal_id_000001` 반환 확인
3. **세션 초기화**: session-init Lambda → 프로젝트 전체 CRAM+CRAI 6개 symlink 매핑 반환 확인
4. **데이터 마이그레이션**: PoC 버킷 → 프로덕션 버킷 45.7 GiB CRAM + 3.1 GiB 참조 게놈 복사 (273 MiB/s)
5. **EC2 워크스테이션**: SSM 접속 → mount-s3 마운트 → setup-project.sh → symlink 생성 → samtools CRAM 헤더 읽기 **성공**

---

## 11. 생성된 파일 목록

| 파일 | 라인 수 | 설명 |
|---|---:|---|
| `scripts/01_install_tools.sh` | ~50 | samtools, mount-s3, fusepy 설치 |
| `scripts/02_generate_cram.sh` | ~120 | 합성 CRAM 데이터 생성 (wgsim + samtools) |
| `scripts/03_setup_s3.sh` | ~100 | S3 버킷 생성 및 업로드 |
| `scripts/04_mount_s3.sh` | ~150 | Mountpoint S3 마운트/언마운트/상태 |
| **`scripts/eid_fuse.py`** | **994** | **Custom FUSE (dxfuse 아키텍처 재현)** |
| `scripts/setup_symlink_layer.sh` | ~130 | Symlink 레이어 생성 |
| `scripts/cram_access.py` | ~200 | htslib S3 직접 접근 래퍼 |
| `scripts/run_tests.sh` | ~280 | 기능 테스트 (4개 접근법) |
| `scripts/benchmark.sh` | ~270 | 성능 벤치마크 |
| `scripts/verify_byte_range.py` | ~280 | 바이트 범위 MD5 검증 |
| `data/mapping/eid_mapping.json` | 12 | EID <-> internal_id 매핑 (합성) |
| `data/mapping/eid_mapping_1kg.json` | 13 | EID <-> internal_id 매핑 (1000 Genomes) |
| **CDK 인프라** | | |
| `infra/bin/app.ts` | ~50 | CDK 앱 엔트리포인트 (5개 스택 인스턴스화) |
| `infra/lib/config/constants.ts` | ~40 | 환경 상수 (CIDR, 이름, 프리픽스) |
| `infra/lib/stacks/network-stack.ts` | ~80 | VPC, 서브넷, Gateway Endpoint, SG |
| `infra/lib/stacks/storage-stack.ts` | ~120 | S3 + KMS + CloudTrail + 로그 버킷 |
| `infra/lib/stacks/database-stack.ts` | ~40 | DynamoDB 테이블 + GSI |
| `infra/lib/stacks/auth-stack.ts` | ~180 | Cognito User Pool + Identity Pool |
| `infra/lib/stacks/compute-stack.ts` | ~225 | Lambda ×3, EC2 워크스테이션 |
| `infra/lambda/eid-resolver/index.ts` | ~60 | 단건 EID → internal_id 조회 |
| `infra/lambda/session-init/index.ts` | ~90 | 프로젝트 전체 매핑 반환 |
| `infra/lambda/data-seeder/index.ts` | ~120 | JSON → DynamoDB 시딩 |
| `infra/test/stacks.test.ts` | ~235 | CDK Assertions 테스트 (19개) |

---

## 12. 비용 분석

### 12.1 분석 목적

Section 8에서 제안한 프로덕션 아키텍처(Mountpoint S3 + Symlink + DynamoDB 동적 매핑)의 비용 효율성을 정량화하고, 전통적인 데이터 복제 방식과 비교한다. 핵심 질문: **100명의 연구자가 동일 데이터를 접근할 때, FUSE 기반 공유 방식과 개별 스토리지 복사 방식의 비용 차이는 얼마인가?**

### 12.2 비교 시나리오

| 시나리오 | 설명 | 스토리지 모델 |
|----------|------|---------------|
| **A: Mountpoint S3 + Symlink** | S3에 1카피 저장, 100명이 Mountpoint S3로 공유 접근 | S3 × 1 |
| **B-1: EFS 개별 복사** | S3 소스 + 연구자별 EFS에 전체 복사본 | S3 × 1 + EFS × 100 |
| **B-2: EBS 개별 복사** | S3 소스 + 연구자별 EBS gp3에 전체 복사본 | S3 × 1 + EBS × 100 |

### 12.3 기본 가정

| 항목 | 값 | 근거 |
|------|-----|------|
| 연구자 수 | 100명 | |
| 일일 samtools 쿼리 (연구자당) | 50회 | 영역 쿼리 기반 분석 |
| 쿼리당 S3 GET 요청 | 100회 | CRAM 인덱스 + 데이터 블록 |
| 월 근무일 | 22일 | |
| 월 총 S3 GET 요청 | 11,000,000회 | 100 × 50 × 100 × 22 |
| EC2 개별 사용 시간 | 8시간/일 | 연구자 업무 시간 |
| 공유 워크스테이션 | 24/7 가동 | 730시간/월 |

### 12.4 AWS 서울 리전 (ap-northeast-2) 단가

| 서비스 | 단가 (USD) | 단위 |
|--------|-----------|------|
| S3 Standard | $0.025 | GB-월 (첫 50TB) |
| S3 GET 요청 | $0.00035 | 1,000건 |
| EBS gp3 | $0.0912 | GB-월 |
| EFS Standard | $0.36 | GB-월 |
| EC2 t3.large | $0.104 | 시간 |
| Lambda | $0.20/1M건 + $0.0000167/GB-초 | |
| DynamoDB On-Demand RRU | $0.375 | 100만건 |
| Mountpoint S3 | **무료** | 추가 비용 없음 |
| S3 VPC Gateway Endpoint | **무료** | 데이터 전송 무료 |

> **참고**: EFS는 S3 대비 **14.4배**, EBS gp3는 S3 대비 **3.6배** GB당 비용이 높다.

### 12.5 소규모 프로젝트 비용 비교 (50 GiB, PoC 수준)

#### Scenario A: Mountpoint S3 + Symlink (공유 워크스테이션 1대)

| 구성 요소 | 월별 비용 | 비율 |
|-----------|----------|------|
| S3 스토리지 (1 복사본) | $1.25 | 1.5% |
| S3 GET 요청 (1,100만건) | $3.85 | 4.7% |
| Lambda (EID 해석) | $0.04 | 0.1% |
| DynamoDB (메타데이터) | $0.08 | 0.1% |
| EC2 공유 워크스테이션 1대 | $75.92 | 93.6% |
| Mountpoint S3 | $0.00 | - |
| **월별 합계** | **$81** | |
| **연간 합계** | **$974** | |
| **연구자 1인당 월 비용** | **$0.81** | |

#### Scenario B-1: EFS 개별 복사

| 구성 요소 | 월별 비용 | 비율 |
|-----------|----------|------|
| S3 스토리지 (소스) | $1.25 | 0.0% |
| EFS 스토리지 (50 GiB × 100) | $1,800.00 | 49.6% |
| EC2 개별 인스턴스 100대 | $1,830.40 | 50.4% |
| **월별 합계** | **$3,632** | |
| **연간 합계** | **$43,580** | |
| **연구자 1인당 월 비용** | **$36.32** | |

#### Scenario B-2: EBS 개별 복사

| 구성 요소 | 월별 비용 | 비율 |
|-----------|----------|------|
| S3 스토리지 (소스) | $1.25 | 0.1% |
| EBS gp3 스토리지 (50 GiB × 100) | $456.00 | 19.9% |
| EC2 개별 인스턴스 100대 | $1,830.40 | 80.0% |
| **월별 합계** | **$2,288** | |
| **연간 합계** | **$27,452** | |
| **연구자 1인당 월 비용** | **$22.88** | |

#### 소규모 비교 요약

| 시나리오 | 월 비용 | 연 비용 | A 대비 배율 | 절감율 |
|----------|--------|--------|------------|--------|
| A: S3 + Symlink | $81 | $974 | 기준선 | - |
| B-1: EFS 복사 | $3,632 | $43,580 | **44.8x** | 97.8% |
| B-2: EBS 복사 | $2,288 | $27,452 | **28.2x** | 96.5% |

### 12.6 프로덕션 프로젝트 비용 비교 (15 TB, WGS 1,000 샘플)

#### Scenario A: Mountpoint S3 + Symlink (공유 워크스테이션 1대)

| 구성 요소 | 월별 비용 | 비율 |
|-----------|----------|------|
| S3 스토리지 (1 복사본, 15TB) | $384.00 | 82.8% |
| S3 GET 요청 (1,100만건) | $3.85 | 0.8% |
| Lambda (EID 해석) | $0.04 | 0.0% |
| DynamoDB (메타데이터) | $0.08 | 0.0% |
| EC2 공유 워크스테이션 1대 | $75.92 | 16.4% |
| Mountpoint S3 | $0.00 | - |
| **월별 합계** | **$464** | |
| **연간 합계** | **$5,567** | |
| **연구자 1인당 월 비용** | **$4.64** | |

#### Scenario B-1: EFS 개별 복사

| 구성 요소 | 월별 비용 | 비율 |
|-----------|----------|------|
| S3 스토리지 (소스) | $384.00 | 0.1% |
| EFS 스토리지 (15TB × 100 = 1.5PB) | $552,960.00 | 99.6% |
| EC2 개별 인스턴스 100대 | $1,830.40 | 0.3% |
| **월별 합계** | **$555,180** | |
| **연간 합계** | **$6,662,162** | |
| **연구자 1인당 월 비용** | **$5,552** | |

#### Scenario B-2: EBS 개별 복사

| 구성 요소 | 월별 비용 | 비율 |
|-----------|----------|------|
| S3 스토리지 (소스) | $384.00 | 0.3% |
| EBS gp3 스토리지 (15TB × 100 = 1.5PB) | $140,083.20 | 98.4% |
| EC2 개별 인스턴스 100대 | $1,830.40 | 1.3% |
| **월별 합계** | **$142,303** | |
| **연간 합계** | **$1,707,640** | |
| **연구자 1인당 월 비용** | **$1,423** | |

#### 프로덕션 비교 요약

| 시나리오 | 월 비용 | 연 비용 | A 대비 배율 | 연간 절감액 |
|----------|--------|--------|------------|-----------|
| A: S3 + Symlink | $464 | $5,567 | 기준선 | - |
| B-1: EFS 복사 | $555,180 | $6.66M | **1,197x** | **$6,656,595** |
| B-2: EBS 복사 | $142,303 | $1.71M | **307x** | **$1,702,073** |

### 12.7 연구자 수에 따른 비용 곡선 (15 TB 기준)

| 연구자 수 | A: S3+Symlink | B-1: EFS | B-2: EBS | 최저 비용 |
|----------|--------------|---------|---------|----------|
| 1명 | $460 | $5,932 | $1,803 | A |
| 5명 | $460 | $28,124 | $7,480 | A |
| 10명 | $460 | $55,863 | $14,575 | A |
| 25명 | $461 | $139,082 | $35,862 | A |
| 50명 | $462 | $277,779 | $71,341 | A |
| 100명 | $464 | $555,174 | $142,298 | A |
| 200명 | $468 | $1,109,965 | $284,211 | A |
| 500명 | $479 | $2,774,336 | $709,952 | A |

**핵심 관찰**: Scenario A는 연구자 수가 1명에서 500명으로 증가해도 비용이 $460 → $479로 거의 변동 없다. S3 GET 요청 비용만 소폭 증가하며, 스토리지는 항상 1카피로 유지되기 때문이다. 반면 Scenario B는 연구자 수에 정비례하여 선형 증가한다. **손익분기점은 존재하지 않으며, 연구자가 1명인 경우에도 Scenario A가 유리하다.**

### 12.8 비용 구조 분석

**Scenario A: Mountpoint S3 + Symlink (프로덕션 15TB)**

| 구성 요소 | 월별 비용 | 비율 | 비중 |
|-----------|----------|------|------|
| S3 스토리지 (1카피) | $384 | 82.8% | ████████████████████ |
| EC2 공유 워크스테이션 | $76 | 16.4% | ████ |
| S3 GET + Lambda + DynamoDB | $4 | 0.8% | - |
| **합계** | **$464/월** | | |

**Scenario B-2: EBS 개별 복사 (프로덕션 15TB)**

| 구성 요소 | 월별 비용 | 비율 | 비중 |
|-----------|----------|------|------|
| EBS 스토리지 복제 (100카피) | $140,083 | 98.4% | ████████████████████ |
| EC2 개별 100대 | $1,830 | 1.3% | - |
| S3 소스 | $384 | 0.3% | - |
| **합계** | **$142,303/월** | | |

- **Scenario A의 비용 지배 요인**: 소규모에서는 EC2(93.6%), 프로덕션 규모에서는 S3 스토리지(82.8%). Lambda, DynamoDB, S3 GET 비용은 합산해도 1% 미만으로 무시 가능 수준.
- **Scenario B의 비용 지배 요인**: 스토리지 복제 비용이 98%+ 차지. 100명 x 15TB = 1.5PB의 중복 스토리지가 비용의 근본 원인.

### 12.9 결론 및 권장사항

1. **Mountpoint S3 + Symlink 방식(Scenario A)은 모든 규모에서 가장 비용 효율적**이다. 프로덕션 규모(15TB, 100연구자)에서 EFS 대비 **99.9%**, EBS 대비 **99.7%** 비용 절감이 가능하다.

2. **프로덕션 규모에서의 연간 절감액**:
   - EFS 개별 복사 대비: **$6,656,595/년** 절감
   - EBS 개별 복사 대비: **$1,702,073/년** 절감

3. **연구자 1인당 월 비용**: Scenario A는 $4.64, EBS 복사는 $1,423, EFS 복사는 $5,552. Scenario A가 **연구자당 300~1,200배 저렴**.

4. **추가 절감 가능 요소**:
   - S3 Intelligent-Tiering: 자주 접근하지 않는 CRAM은 자동으로 저비용 계층으로 이동 (최대 40% 추가 절감)
   - EC2 Savings Plans / Reserved Instance: 공유 워크스테이션에 적용 시 최대 60% 할인
   - S3 Glacier Instant Retrieval: 아카이브 데이터에 적용 시 68% 추가 절감 (단, Mountpoint S3 비호환)

---

## 13. 결론

1. **UK Biobank RAP의 dxfuse 아키텍처를 AWS에서 성공적으로 재현**했다. Custom FUSE(`eid_fuse.py`)는 SQLite 메타데이터 DB, EID->S3 key 해석, 프리페치 상태머신 등 dxfuse의 핵심 구조를 충실히 구현하며, samtools를 통한 CRAM 읽기가 정상 동작한다.

2. **3가지 접근법 모두 기능적으로 정확**하다. 합성 데이터(3.3 MiB) 17개 + 실전 데이터(16.4 GiB) 10개 = 총 27개 기능 테스트 전수 통과. 합성 9개 + 실전 9개 = 총 18개 바이트 범위 검증에서 모든 소스 간 bit-for-bit 일치를 확인했다.

3. **1000 Genomes 실전 WGS 데이터(16.4 GiB)에서도 동일한 결론이 유효**하다. 30x 고심도 WGS CRAM 파일에 대해 chr22:16M-16.1M 영역에서 25,083 reads를 정확히 읽었으며, 15GB 오프셋까지 바이트 범위 정합성이 검증되었다.

4. **성능 측면에서 Approach B (Symlink + Mountpoint S3)가 최적**이다.
   - 합성 데이터: 로컬 대비 1.1~1.7x 오버헤드
   - 실전 데이터: 헤더 18ms, 영역 쿼리 56ms (Custom FUSE 대비 4.4~9.1x 빠름)
   - Rust 기반 mount-s3의 커널 FUSE 구현과 로컬 캐시가 핵심 성능 요인

5. **대용량 파일에서 Custom FUSE의 상대적 성능 개선 확인**. 합성 데이터(7~13x 차이) 대비 실전 데이터(4.4~9.1x 차이)에서 FUSE 오버헤드가 감소. 프리페치 엔진의 효율이 대형 파일에서 더 높아지는 것으로 분석된다.

6. **프로덕션에서는 Approach B 기반 + DynamoDB 동적 매핑**을 권장한다. dxfuse의 OOM/불안정성 문제를 회피하면서, EID 실시간 변환과 감사 로그를 AWS 네이티브 서비스로 제공할 수 있다.

7. **CDK 인프라 구현 및 배포 완료**. 5개 CDK 스택(Network, Storage, Database, Auth, Compute)을 구현하여 ap-northeast-2에 배포하였으며, DynamoDB 시딩 → Lambda EID 해석 → Mountpoint S3 마운트 → Symlink 생성 → samtools CRAM 읽기까지 End-to-End 검증을 완료하였다.

8. **비용 분석 결과, Mountpoint S3 + Symlink 방식이 전통적 데이터 복사 방식 대비 96~99.9% 비용 절감**을 달성한다. 100명의 연구자가 15TB 데이터를 공유 접근 시 월 $464(연 $5,567)이며, 동일 데이터를 EBS에 개별 복사할 경우 월 $142,303(연 $1.71M)으로 307배 차이가 발생한다. 데이터 규모와 연구자 수가 증가할수록 이 격차는 더욱 확대된다.
