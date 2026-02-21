#!/usr/bin/env python3
from __future__ import annotations

"""
eid_fuse.py - Custom FUSE filesystem mirroring dxfuse architecture for AWS S3.

Implements the core dxfuse patterns:
  - SQLite metadata DB (metadata_db.go): inode->file mapping, namespace resolution
  - FUSE operations (dxfuse.go): open, read, readdir, getattr with file handles
  - Prefetch engine (prefetch.go): sequential access detection + async read-ahead
  - S3 byte-range reads (dx_ops.go): presigned URL / GetObject with Range header

Architecture mapping (dxfuse -> eid_fuse.py):
  metadata_db.go SQLite   -> self.db (SQLite: data_objects, namespace, directories)
  dxfuse.go FileHandle    -> self.file_handles dict
  dx_ops.go DxDownloadURL -> S3 presigned URL generation
  prefetch.go state machine -> PrefetchManager with NIL->DETECT_SEQ->PREFETCH->EOF
  dx_describe.go BulkDescribe -> S3 HeadObject batch calls

Usage:
    python3 scripts/eid_fuse.py /mnt/project \\
        --bucket <YOUR_BUCKET_NAME> \\
        --project project_001 \\
        --mapping data/mapping/eid_mapping.json

    # Then use as normal filesystem:
    ls /mnt/project/
    samtools view /mnt/project/EID_1234567.cram chr22:16M-17M
"""

import argparse
import errno
import json
import logging
import os
import sqlite3
import stat
import sys
import threading
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from enum import IntEnum

import boto3
from botocore.config import Config as BotoConfig

try:
    from fuse import FUSE, FuseOSError, Operations
except ImportError:
    print("ERROR: fusepy not installed. Run: pip3 install fusepy", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG_FORMAT = "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)
logger = logging.getLogger("eid_fuse")


# ---------------------------------------------------------------------------
# Constants (matching dxfuse where applicable)
# ---------------------------------------------------------------------------
INODE_ROOT = 1
OBJ_TYPE_DIR = 1       # nsDirType in dxfuse
OBJ_TYPE_FILE = 2      # nsDataObjType in dxfuse

PRESIGNED_URL_EXPIRY = 3600    # 1 hour (dxfuse uses per-session download URLs)
ATTR_CACHE_TTL = 86400         # 1 day (dxfuse uses 1 year for immutable files)

# Prefetch constants (adapted from dxfuse prefetch.go for S3 optimization)
PREFETCH_MIN_IO_SIZE = 8 * 1024 * 1024    # 8 MB (dxfuse: 1 MB; S3 benefits from larger)
PREFETCH_MAX_IO_SIZE = 128 * 1024 * 1024  # 128 MB
PREFETCH_GROWTH_FACTOR = 4                 # dxfuse: 4x growth
PREFETCH_MAX_IOVECS = 4                    # max cached chunks per file
PREFETCH_NUM_SLOTS = 64                    # slot bitmap size for touch detection
PREFETCH_SEQ_THRESHOLD = 0.5              # fraction of slots touched -> sequential


# ---------------------------------------------------------------------------
# Prefetch Engine (mirrors dxfuse prefetch.go)
# ---------------------------------------------------------------------------
class PrefetchState(IntEnum):
    """File-level prefetch states (PFM states in dxfuse)."""
    NIL = 0
    DETECT_SEQ = 1
    PREFETCH_IN_PROGRESS = 2
    EOF = 3


class IovecState(IntEnum):
    """IO vector states (IOV states in dxfuse)."""
    HOLE = 0
    IN_FLIGHT = 1
    DONE = 2
    ERRORED = 3


class Iovec:
    """A cached data chunk, corresponding to dxfuse's Iovec struct."""

    __slots__ = ('start', 'end', 'state', 'data', 'touched_slots', 'cond')

    def __init__(self, start: int, end: int):
        self.start = start
        self.end = end
        self.state = IovecState.HOLE
        self.data = b''
        self.touched_slots = set()
        self.cond = threading.Condition()

    @property
    def size(self):
        return self.end - self.start

    def touch_fraction(self):
        if self.size == 0:
            return 1.0
        slot_size = max(1, self.size // PREFETCH_NUM_SLOTS)
        total_slots = max(1, self.size // slot_size)
        return len(self.touched_slots) / total_slots

    def mark_touched(self, offset: int, size: int):
        """Record which slots within this iovec have been accessed."""
        if self.size == 0:
            return
        slot_size = max(1, self.size // PREFETCH_NUM_SLOTS)
        rel_start = max(0, offset - self.start)
        rel_end = min(self.size, offset + size - self.start)
        for s in range(rel_start // slot_size, (rel_end + slot_size - 1) // slot_size):
            self.touched_slots.add(s)


class PrefetchFileState:
    """Per-file prefetch state (PrefetchFileMetadata in dxfuse)."""

    def __init__(self, file_size: int):
        self.state = PrefetchState.NIL
        self.file_size = file_size
        self.iovecs: list[Iovec] = []
        self.current_io_size = PREFETCH_MIN_IO_SIZE
        self.lock = threading.Lock()

    def reset(self):
        self.state = PrefetchState.NIL
        self.iovecs.clear()
        self.current_io_size = PREFETCH_MIN_IO_SIZE


class PrefetchManager:
    """
    Global prefetch manager (PrefetchGlobalState in dxfuse).

    Detects sequential access patterns and prefetches upcoming data chunks
    from S3 using a thread pool.
    """

    def __init__(self, s3_client, bucket: str, max_workers: int = 8):
        self.s3 = s3_client
        self.bucket = bucket
        self.file_states: dict[int, PrefetchFileState] = {}  # handle_id -> state
        self.executor = ThreadPoolExecutor(max_workers=max_workers,
                                           thread_name_prefix="prefetch")
        self.lock = threading.Lock()
        self._stats = defaultdict(int)

    def register(self, handle_id: int, file_size: int):
        with self.lock:
            self.file_states[handle_id] = PrefetchFileState(file_size)

    def unregister(self, handle_id: int):
        with self.lock:
            self.file_states.pop(handle_id, None)

    def cache_lookup(self, handle_id: int, s3_key: str,
                     offset: int, size: int) -> bytes | None:
        """
        Check prefetch cache for data. Mirrors prefetch.go CacheLookup().

        Returns cached data on hit, None on miss.
        Also triggers sequential access detection and prefetch scheduling.
        """
        with self.lock:
            pfs = self.file_states.get(handle_id)
            if pfs is None:
                return None

        with pfs.lock:
            return self._cache_lookup_locked(pfs, handle_id, s3_key, offset, size)

    def _cache_lookup_locked(self, pfs: PrefetchFileState, handle_id: int,
                             s3_key: str, offset: int, size: int) -> bytes | None:
        # --- State: NIL -> start detection ---
        if pfs.state == PrefetchState.NIL:
            pfs.state = PrefetchState.DETECT_SEQ
            # Create initial iovecs aligned on io_size boundaries
            aligned_start = (offset // pfs.current_io_size) * pfs.current_io_size
            for i in range(2):
                iov_start = aligned_start + i * pfs.current_io_size
                iov_end = min(iov_start + pfs.current_io_size, pfs.file_size)
                if iov_start < pfs.file_size:
                    pfs.iovecs.append(Iovec(iov_start, iov_end))
            self._stats['detect_seq_transitions'] += 1
            return None

        # --- Check if offset falls within any cached iovec ---
        for iov in pfs.iovecs:
            if iov.start <= offset < iov.end:
                iov.mark_touched(offset, size)

                if iov.state == IovecState.DONE:
                    # Cache hit
                    rel_start = offset - iov.start
                    rel_end = min(rel_start + size, len(iov.data))
                    self._stats['cache_hits'] += 1
                    # Check if enough slots touched -> trigger prefetch
                    if (pfs.state == PrefetchState.DETECT_SEQ
                            and iov.touch_fraction() >= PREFETCH_SEQ_THRESHOLD):
                        self._start_prefetch(pfs, handle_id, s3_key)
                    return iov.data[rel_start:rel_end]

                elif iov.state == IovecState.IN_FLIGHT:
                    # Wait for in-flight IO (blocking, like dxfuse's cond.Wait)
                    self._stats['cache_waits'] += 1
                    with iov.cond:
                        while iov.state == IovecState.IN_FLIGHT:
                            iov.cond.wait(timeout=30)
                    if iov.state == IovecState.DONE:
                        rel_start = offset - iov.start
                        rel_end = min(rel_start + size, len(iov.data))
                        return iov.data[rel_start:rel_end]
                    # Errored - fall through to cache miss
                    break

        # --- Cache miss ---
        self._stats['cache_misses'] += 1

        # If offset is outside all iovecs, reset detection (non-sequential)
        if pfs.iovecs and (offset < pfs.iovecs[0].start
                           or offset >= pfs.iovecs[-1].end):
            pfs.reset()

        return None

    def _start_prefetch(self, pfs: PrefetchFileState, handle_id: int, s3_key: str):
        """Transition to PREFETCH_IN_PROGRESS and schedule async reads."""
        pfs.state = PrefetchState.PREFETCH_IN_PROGRESS
        self._stats['prefetch_starts'] += 1
        logger.debug("Prefetch activated for handle %d (io_size=%d)",
                     handle_id, pfs.current_io_size)

        # Schedule fetches for all HOLE iovecs
        for iov in pfs.iovecs:
            if iov.state == IovecState.HOLE:
                iov.state = IovecState.IN_FLIGHT
                self.executor.submit(self._fetch_iovec, s3_key, iov)

        # Extend cache window: add new iovecs beyond current range
        if pfs.iovecs:
            last_end = pfs.iovecs[-1].end
            while len(pfs.iovecs) < PREFETCH_MAX_IOVECS and last_end < pfs.file_size:
                new_end = min(last_end + pfs.current_io_size, pfs.file_size)
                new_iov = Iovec(last_end, new_end)
                new_iov.state = IovecState.IN_FLIGHT
                pfs.iovecs.append(new_iov)
                self.executor.submit(self._fetch_iovec, s3_key, new_iov)
                last_end = new_end

            # Grow IO size for next round (dxfuse: 4x growth)
            pfs.current_io_size = min(
                pfs.current_io_size * PREFETCH_GROWTH_FACTOR,
                PREFETCH_MAX_IO_SIZE
            )

        # Check for EOF
        if pfs.iovecs and pfs.iovecs[-1].end >= pfs.file_size:
            pfs.state = PrefetchState.EOF

    def _fetch_iovec(self, s3_key: str, iov: Iovec):
        """Worker: fetch data from S3 for a single iovec (prefetchIoWorker in dxfuse)."""
        try:
            resp = self.s3.get_object(
                Bucket=self.bucket,
                Key=s3_key,
                Range=f"bytes={iov.start}-{iov.end - 1}"
            )
            iov.data = resp['Body'].read()
            iov.state = IovecState.DONE
            self._stats['prefetch_bytes'] += len(iov.data)
        except Exception as e:
            logger.warning("Prefetch failed for %s [%d-%d]: %s",
                           s3_key, iov.start, iov.end, e)
            iov.state = IovecState.ERRORED
        finally:
            with iov.cond:
                iov.cond.notify_all()

    def evict_old_iovecs(self, pfs: PrefetchFileState, current_offset: int):
        """Discard iovecs that are fully behind the current read position."""
        with pfs.lock:
            pfs.iovecs = [
                iov for iov in pfs.iovecs
                if iov.end > current_offset
            ]

    def get_stats(self) -> dict:
        return dict(self._stats)

    def shutdown(self):
        self.executor.shutdown(wait=False)


# ---------------------------------------------------------------------------
# SQLite Metadata DB (mirrors dxfuse metadata_db.go)
# ---------------------------------------------------------------------------
class MetadataDB:
    """
    SQLite-based metadata store mirroring dxfuse's metadata_db.go.

    Tables:
      data_objects: inode -> file metadata (s3_key, size, mtime, eid)
      namespace:    (parent, name) -> inode (path resolution)
      directories:  inode -> directory metadata (populated flag)
    """

    SCHEMA = """
        CREATE TABLE IF NOT EXISTS data_objects (
            inode INTEGER PRIMARY KEY,
            s3_key TEXT NOT NULL,
            eid TEXT NOT NULL,
            size INTEGER NOT NULL DEFAULT 0,
            mtime REAL NOT NULL DEFAULT 0,
            ctime REAL NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS namespace (
            parent TEXT NOT NULL,
            name TEXT NOT NULL,
            obj_type INTEGER NOT NULL,
            inode INTEGER NOT NULL,
            PRIMARY KEY (parent, name)
        );
        CREATE TABLE IF NOT EXISTS directories (
            inode INTEGER PRIMARY KEY,
            populated INTEGER NOT NULL DEFAULT 0,
            mtime REAL NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_eid ON data_objects (eid);
        CREATE INDEX IF NOT EXISTS idx_s3key ON data_objects (s3_key);
        CREATE INDEX IF NOT EXISTS idx_ns_parent ON namespace (parent);
        CREATE INDEX IF NOT EXISTS idx_ns_inode ON namespace (inode);
    """

    def __init__(self):
        # Shared in-memory SQLite: all threads share one DB via URI + shared cache
        self._local = threading.local()
        self._db_uri = "file:eid_metadata?mode=memory&cache=shared"
        self._init_lock = threading.Lock()
        self._initialized = False
        # Keep one reference connection alive so the shared DB is not garbage-collected
        self._keeper = sqlite3.connect(self._db_uri, uri=True)
        self._keeper.executescript(self.SCHEMA)
        self._initialized = True

    def _get_conn(self) -> sqlite3.Connection:
        conn = getattr(self._local, 'conn', None)
        if conn is None:
            conn = sqlite3.connect(self._db_uri, uri=True)
            conn.row_factory = sqlite3.Row
            self._local.conn = conn
        return conn

    def insert_directory(self, inode: int, mtime: float = 0):
        conn = self._get_conn()
        conn.execute(
            "INSERT OR REPLACE INTO directories (inode, populated, mtime) VALUES (?, 1, ?)",
            (inode, mtime)
        )
        conn.commit()

    def insert_namespace_entry(self, parent: str, name: str, obj_type: int, inode: int):
        conn = self._get_conn()
        conn.execute(
            "INSERT OR REPLACE INTO namespace (parent, name, obj_type, inode) VALUES (?, ?, ?, ?)",
            (parent, name, obj_type, inode)
        )
        conn.commit()

    def insert_data_object(self, inode: int, s3_key: str, eid: str,
                           size: int = 0, mtime: float = 0):
        conn = self._get_conn()
        conn.execute(
            "INSERT OR REPLACE INTO data_objects (inode, s3_key, eid, size, mtime, ctime) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (inode, s3_key, eid, size, mtime, mtime)
        )
        conn.commit()

    def lookup_by_path(self, parent: str, name: str) -> dict | None:
        conn = self._get_conn()
        row = conn.execute(
            "SELECT obj_type, inode FROM namespace WHERE parent = ? AND name = ?",
            (parent, name)
        ).fetchone()
        if row is None:
            return None
        return dict(row)

    def lookup_data_object(self, inode: int) -> dict | None:
        conn = self._get_conn()
        row = conn.execute(
            "SELECT * FROM data_objects WHERE inode = ?", (inode,)
        ).fetchone()
        if row is None:
            return None
        return dict(row)

    def list_directory(self, parent: str) -> list[dict]:
        conn = self._get_conn()
        rows = conn.execute(
            "SELECT name, obj_type, inode FROM namespace WHERE parent = ? ORDER BY name",
            (parent,)
        ).fetchall()
        return [dict(r) for r in rows]

    def is_directory(self, inode: int) -> bool:
        conn = self._get_conn()
        row = conn.execute(
            "SELECT inode FROM directories WHERE inode = ?", (inode,)
        ).fetchone()
        return row is not None

    def get_file_count(self) -> int:
        conn = self._get_conn()
        row = conn.execute("SELECT COUNT(*) FROM data_objects").fetchone()
        return row[0]


# ---------------------------------------------------------------------------
# EID FUSE Filesystem (mirrors dxfuse.go)
# ---------------------------------------------------------------------------
class EIDFuse(Operations):
    """
    Custom FUSE filesystem that presents EID-named CRAM files backed by S3.

    Mirrors dxfuse architecture:
      - SQLite metadata DB for path -> inode -> S3 key resolution
      - File handle table with presigned URLs
      - Prefetch engine for sequential read optimization
      - S3 GetObject with Range header for byte-range reads
    """

    def __init__(self, bucket: str, region: str, project_id: str,
                 mapping_file: str, s3_prefix: str = "internal/cram/"):
        self.bucket = bucket
        self.region = region
        self.project_id = project_id
        self.s3_prefix = s3_prefix

        # S3 client
        self.s3 = boto3.client(
            's3',
            region_name=region,
            config=BotoConfig(
                signature_version='s3v4',
                max_pool_connections=50,
                retries={'max_attempts': 3, 'mode': 'adaptive'}
            )
        )

        # [metadata_db.go] SQLite metadata database
        self.db = MetadataDB()

        # [dxfuse.go] File handle table
        self.file_handles: dict[int, dict] = {}
        self._next_handle_id = 1
        self._fh_lock = threading.Lock()

        # [prefetch.go] Prefetch engine
        self.prefetch = PrefetchManager(self.s3, bucket)

        # Inode counter
        self._next_inode = INODE_ROOT + 1
        self._inode_lock = threading.Lock()

        # Stats
        self._stats = defaultdict(int)
        self._start_time = time.time()

        # Initialize filesystem
        self._init_root()
        self._load_eid_mapping(mapping_file, project_id)
        self._populate_metadata()

        logger.info("EIDFuse initialized: bucket=%s project=%s files=%d",
                     bucket, project_id, self.db.get_file_count())

    def _alloc_inode(self) -> int:
        with self._inode_lock:
            inode = self._next_inode
            self._next_inode += 1
            return inode

    def _init_root(self):
        """Initialize root directory (inode 1)."""
        now = time.time()
        self.db.insert_directory(INODE_ROOT, now)

    def _load_eid_mapping(self, mapping_file: str, project_id: str):
        """Load EID -> internal_id mapping from JSON file."""
        with open(mapping_file) as f:
            all_mappings = json.load(f)

        if project_id not in all_mappings:
            raise ValueError(
                f"Project '{project_id}' not found. "
                f"Available: {list(all_mappings.keys())}"
            )

        self._eid_to_internal = all_mappings[project_id]
        logger.info("Loaded %d EID mappings for project %s",
                     len(self._eid_to_internal), project_id)

    def _populate_metadata(self):
        """
        Populate metadata DB with file information from S3.
        Mirrors dxfuse's lazy directory population (metadata_db.go).
        """
        now = time.time()

        for eid, internal_id in self._eid_to_internal.items():
            # CRAM file
            cram_s3_key = f"{self.s3_prefix}{internal_id}.cram"
            cram_size = self._get_s3_file_size(cram_s3_key)

            cram_inode = self._alloc_inode()
            self.db.insert_data_object(
                inode=cram_inode,
                s3_key=cram_s3_key,
                eid=eid,
                size=cram_size,
                mtime=now
            )
            self.db.insert_namespace_entry(
                parent="/",
                name=f"{eid}.cram",
                obj_type=OBJ_TYPE_FILE,
                inode=cram_inode
            )

            # CRAI index file
            crai_s3_key = f"{self.s3_prefix}{internal_id}.cram.crai"
            crai_size = self._get_s3_file_size(crai_s3_key)

            if crai_size > 0:
                crai_inode = self._alloc_inode()
                self.db.insert_data_object(
                    inode=crai_inode,
                    s3_key=crai_s3_key,
                    eid=eid,
                    size=crai_size,
                    mtime=now
                )
                self.db.insert_namespace_entry(
                    parent="/",
                    name=f"{eid}.cram.crai",
                    obj_type=OBJ_TYPE_FILE,
                    inode=crai_inode
                )

            logger.info("  %s.cram -> %s (%d bytes)", eid, cram_s3_key, cram_size)

    def _get_s3_file_size(self, s3_key: str) -> int:
        """Get file size via S3 HeadObject (mirrors dx_describe.go)."""
        try:
            resp = self.s3.head_object(Bucket=self.bucket, Key=s3_key)
            return resp['ContentLength']
        except self.s3.exceptions.ClientError as e:
            if e.response['Error']['Code'] == '404':
                logger.warning("S3 object not found: s3://%s/%s", self.bucket, s3_key)
                return 0
            raise

    def _resolve_path(self, path: str) -> tuple[int, dict | None]:
        """
        Resolve filesystem path to inode and metadata.
        Mirrors dxfuse's namespace table lookup.

        Returns: (inode, data_object_dict or None for directories)
        """
        if path == '/':
            return INODE_ROOT, None

        # Split path into parent directory and name
        parent = os.path.dirname(path)
        name = os.path.basename(path)
        if not parent:
            parent = '/'

        ns_entry = self.db.lookup_by_path(parent, name)
        if ns_entry is None:
            return -1, None

        inode = ns_entry['inode']

        if ns_entry['obj_type'] == OBJ_TYPE_FILE:
            data_obj = self.db.lookup_data_object(inode)
            return inode, data_obj

        return inode, None

    # --- FUSE Operations (mirrors dxfuse.go) ---

    def getattr(self, path, fh=None):
        """
        Get file attributes. Mirrors dxfuse GetInodeAttributes().
        Uses metadata DB for cached lookups (no S3 call).
        """
        self._stats['getattr'] += 1

        inode, data_obj = self._resolve_path(path)
        if inode < 0:
            raise FuseOSError(errno.ENOENT)

        now = time.time()

        if data_obj is not None:
            # Regular file
            return {
                'st_mode': stat.S_IFREG | 0o444,
                'st_nlink': 1,
                'st_size': data_obj['size'],
                'st_uid': os.getuid(),
                'st_gid': os.getgid(),
                'st_atime': now,
                'st_mtime': data_obj['mtime'],
                'st_ctime': data_obj.get('ctime', data_obj['mtime']),
            }
        else:
            # Directory
            return {
                'st_mode': stat.S_IFDIR | 0o555,
                'st_nlink': 2,
                'st_size': 0,
                'st_uid': os.getuid(),
                'st_gid': os.getgid(),
                'st_atime': now,
                'st_mtime': now,
                'st_ctime': now,
            }

    def readdir(self, path, fh):
        """
        List directory entries. Mirrors dxfuse ReadDir().
        Returns EID-named files from namespace table.
        """
        self._stats['readdir'] += 1

        # Normalize path
        if not path.endswith('/'):
            dir_path = path if path == '/' else path + '/'
        else:
            dir_path = path
        if dir_path != '/':
            dir_path = path

        entries = self.db.list_directory('/' if path == '/' else path)

        yield '.'
        yield '..'
        for entry in entries:
            yield entry['name']

    def open(self, path, flags):
        """
        Open a file. Mirrors dxfuse OpenFile() / getRemoteFileHandleForRead().

        1. Resolve path (EID) -> namespace -> inode -> s3_key
        2. Generate S3 presigned URL (analogous to dxfuse /file-xxxx/download)
        3. Create FileHandle entry in fhTable
        4. Register with prefetch engine
        """
        self._stats['open'] += 1

        # Read-only check
        if (flags & os.O_WRONLY) or (flags & os.O_RDWR):
            raise FuseOSError(errno.EROFS)

        inode, data_obj = self._resolve_path(path)
        if inode < 0 or data_obj is None:
            raise FuseOSError(errno.ENOENT)

        # Generate presigned URL (mirrors dx_ops.go DxFileCloseAndWait/download)
        s3_key = data_obj['s3_key']
        try:
            presigned_url = self.s3.generate_presigned_url(
                'get_object',
                Params={'Bucket': self.bucket, 'Key': s3_key},
                ExpiresIn=PRESIGNED_URL_EXPIRY
            )
        except Exception as e:
            logger.error("Failed to generate presigned URL for %s: %s", s3_key, e)
            raise FuseOSError(errno.EIO)

        # Create file handle (mirrors dxfuse fhTable)
        with self._fh_lock:
            handle_id = self._next_handle_id
            self._next_handle_id += 1
            self.file_handles[handle_id] = {
                'inode': inode,
                's3_key': s3_key,
                'presigned_url': presigned_url,
                'size': data_obj['size'],
                'eid': data_obj['eid'],
                'opened_at': time.time(),
            }

        # Register with prefetch engine
        self.prefetch.register(handle_id, data_obj['size'])

        logger.debug("Opened %s (handle=%d, s3_key=%s, size=%d)",
                      path, handle_id, s3_key, data_obj['size'])
        return handle_id

    def read(self, path, size, offset, fh):
        """
        Read file data. Mirrors dxfuse ReadFile() + prefetch.go CacheLookup().

        1. Check prefetch cache (L1)
        2. On miss: S3 GetObject with Range header
        3. Sequential access detection triggers async prefetch
        """
        self._stats['read'] += 1
        self._stats['read_bytes'] += size

        handle = self.file_handles.get(fh)
        if handle is None:
            raise FuseOSError(errno.EBADF)

        s3_key = handle['s3_key']
        file_size = handle['size']

        # Bounds check
        if offset >= file_size:
            return b''
        if offset + size > file_size:
            size = file_size - offset

        # [prefetch.go] Check prefetch cache (L1)
        cached = self.prefetch.cache_lookup(fh, s3_key, offset, size)
        if cached is not None:
            self._stats['read_cache_hits'] += 1
            return cached

        # [dxfuse.go] Cache miss: direct S3 byte-range read
        self._stats['read_s3_fetches'] += 1
        try:
            resp = self.s3.get_object(
                Bucket=self.bucket,
                Key=s3_key,
                Range=f"bytes={offset}-{offset + size - 1}"
            )
            data = resp['Body'].read()
            return data
        except Exception as e:
            logger.error("S3 read failed: %s [%d-%d]: %s",
                         s3_key, offset, offset + size, e)
            raise FuseOSError(errno.EIO)

    def release(self, path, fh):
        """
        Close file handle. Mirrors dxfuse ReleaseFileHandle().
        Cleans up file handle and prefetch state.
        """
        self._stats['release'] += 1

        # Unregister from prefetch
        self.prefetch.unregister(fh)

        # Remove file handle
        with self._fh_lock:
            handle = self.file_handles.pop(fh, None)

        if handle:
            logger.debug("Closed %s (handle=%d)", path, fh)

        return 0

    def statfs(self, path):
        """Return filesystem statistics."""
        return {
            'f_bsize': 4096,
            'f_frsize': 4096,
            'f_blocks': 1024 * 1024 * 1024,  # ~4 PB virtual
            'f_bfree': 1024 * 1024 * 1024,
            'f_bavail': 1024 * 1024 * 1024,
            'f_files': self.db.get_file_count(),
            'f_ffree': 1024 * 1024,
            'f_namemax': 255,
        }

    def access(self, path, amode):
        """Check file access permissions."""
        inode, _ = self._resolve_path(path)
        if inode < 0:
            raise FuseOSError(errno.ENOENT)
        # Write access denied (read-only FS)
        if amode & os.W_OK:
            raise FuseOSError(errno.EROFS)
        return 0

    # --- Read-only: reject all write operations ---

    def chmod(self, path, mode):
        raise FuseOSError(errno.EROFS)

    def chown(self, path, uid, gid):
        raise FuseOSError(errno.EROFS)

    def create(self, path, mode, fi=None):
        raise FuseOSError(errno.EROFS)

    def mkdir(self, path, mode):
        raise FuseOSError(errno.EROFS)

    def rename(self, old, new):
        raise FuseOSError(errno.EROFS)

    def rmdir(self, path):
        raise FuseOSError(errno.EROFS)

    def symlink(self, target, source):
        raise FuseOSError(errno.EROFS)

    def truncate(self, path, length, fh=None):
        raise FuseOSError(errno.EROFS)

    def unlink(self, path):
        raise FuseOSError(errno.EROFS)

    def utimens(self, path, times=None):
        raise FuseOSError(errno.EROFS)

    def write(self, path, data, offset, fh):
        raise FuseOSError(errno.EROFS)

    # --- Utility ---

    def get_stats(self) -> dict:
        """Return filesystem operation statistics."""
        stats = dict(self._stats)
        stats['uptime_seconds'] = time.time() - self._start_time
        stats['open_handles'] = len(self.file_handles)
        stats['prefetch'] = self.prefetch.get_stats()
        return stats

    def destroy(self, path):
        """Clean up on unmount."""
        logger.info("EIDFuse shutting down...")
        logger.info("Stats: %s", json.dumps(self.get_stats(), indent=2))
        self.prefetch.shutdown()


# ---------------------------------------------------------------------------
# CLI Entry Point
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description='EID FUSE filesystem (dxfuse architecture on AWS S3)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Mount with default settings
  %(prog)s /mnt/project --bucket <YOUR_BUCKET_NAME> --project project_001

  # Mount with custom mapping file
  %(prog)s /mnt/project --bucket my-bucket --project project_002 \\
      --mapping /path/to/eid_mapping.json

  # Debug mode (foreground, verbose logging)
  %(prog)s /mnt/project --bucket my-bucket --project project_001 --debug

  # Usage after mounting:
  ls /mnt/project/
  samtools view -H /mnt/project/EID_1234567.cram
  samtools view -T /ref/GRCh38.fa /mnt/project/EID_1234567.cram chr22:16M-17M
        """
    )

    parser.add_argument('mountpoint', help='Mount point directory')
    parser.add_argument('--bucket', '-b', required=True,
                        help='S3 bucket name')
    parser.add_argument('--project', '-p', required=True,
                        help='Project ID for EID mapping')
    parser.add_argument('--mapping', '-m', default=None,
                        help='EID mapping JSON file (default: data/mapping/eid_mapping.json)')
    parser.add_argument('--region', '-r', default='ap-northeast-2',
                        help='AWS region (default: ap-northeast-2)')
    parser.add_argument('--s3-prefix', default='internal/cram/',
                        help='S3 key prefix for CRAM files (default: internal/cram/)')
    parser.add_argument('--foreground', '-f', action='store_true',
                        help='Run in foreground (do not daemonize)')
    parser.add_argument('--debug', '-d', action='store_true',
                        help='Enable debug logging and foreground mode')
    parser.add_argument('--allow-other', action='store_true', default=True,
                        help='Allow other users to access mount (default: true)')
    parser.add_argument('--stats-interval', type=int, default=0,
                        help='Print stats every N seconds (0=disabled)')

    args = parser.parse_args()

    # Resolve mapping file
    if args.mapping is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        project_dir = os.path.dirname(script_dir)
        args.mapping = os.path.join(project_dir, 'data', 'mapping', 'eid_mapping.json')

    if not os.path.isfile(args.mapping):
        print(f"ERROR: Mapping file not found: {args.mapping}", file=sys.stderr)
        sys.exit(1)

    # Create mount point if needed
    os.makedirs(args.mountpoint, exist_ok=True)

    # Configure logging
    if args.debug:
        logging.getLogger('eid_fuse').setLevel(logging.DEBUG)
        args.foreground = True
    # Suppress noisy libraries even in debug mode
    for noisy in ('botocore', 'boto3', 'urllib3', 's3transfer'):
        logging.getLogger(noisy).setLevel(logging.WARNING)

    # Log configuration
    logger.info("=== EID FUSE Filesystem ===")
    logger.info("Mountpoint:  %s", args.mountpoint)
    logger.info("Bucket:      %s", args.bucket)
    logger.info("Region:      %s", args.region)
    logger.info("Project:     %s", args.project)
    logger.info("Mapping:     %s", args.mapping)
    logger.info("S3 Prefix:   %s", args.s3_prefix)
    logger.info("Foreground:  %s", args.foreground or args.debug)

    # Initialize FUSE filesystem
    try:
        eid_fs = EIDFuse(
            bucket=args.bucket,
            region=args.region,
            project_id=args.project,
            mapping_file=args.mapping,
            s3_prefix=args.s3_prefix,
        )
    except Exception as e:
        logger.error("Failed to initialize EIDFuse: %s", e)
        sys.exit(1)

    # Stats printer thread
    if args.stats_interval > 0:
        def print_stats():
            while True:
                time.sleep(args.stats_interval)
                stats = eid_fs.get_stats()
                logger.info("Stats: %s", json.dumps(stats))

        t = threading.Thread(target=print_stats, daemon=True)
        t.start()

    # Mount FUSE
    logger.info("Mounting filesystem...")
    try:
        FUSE(
            eid_fs,
            args.mountpoint,
            foreground=args.foreground or args.debug,
            allow_other=args.allow_other,
            ro=True,
            nothreads=False,
            # FUSE options for performance
            big_writes=True,
            max_read=131072,        # 128 KB max read size
            max_readahead=1048576,  # 1 MB kernel readahead
            attr_timeout=ATTR_CACHE_TTL,
            entry_timeout=ATTR_CACHE_TTL,
        )
    except RuntimeError as e:
        if "already mounted" in str(e).lower():
            logger.error("Mount point already in use: %s", args.mountpoint)
            logger.error("Unmount with: fusermount -u %s", args.mountpoint)
        else:
            logger.error("FUSE mount failed: %s", e)
        sys.exit(1)


if __name__ == '__main__':
    main()
