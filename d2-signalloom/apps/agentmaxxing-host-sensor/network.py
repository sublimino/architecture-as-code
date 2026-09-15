"""Outbound inference-socket detection without reading /proc/<pid>/fd, fdinfo or net.

Why this module does not look like the proposal
-----------------------------------------------
The SLCD proposal describes socket attribution as "matching local socket inodes from
/proc/net/tcp to process file descriptors under /proc/<pid>/fd/". That is how ``ss -p``
and ``lsof`` do it, and it cannot be built here: ``fd``, ``fdinfo`` and ``net`` are all
members of :data:`proc.PROHIBITED_PROC_ENTRIES`, each pinned by a dedicated P1-4 negative
test. Building the proposal as written requires deleting from that set, which is a
mission-wide stop-and-report condition -- not a refactor this card may perform.

The prohibited set is not an obstacle to route around, because the kernel offers a second,
entirely separate interface that answers the same question. ``NETLINK_SOCK_DIAG`` emits
``INET_DIAG_CGROUP_ID`` for every socket, unconditionally, with no privilege requirement and
no ``idiag_ext`` bit (the field is a ``u8``, so extension 21 could not be requested even if
one wanted to). A process's cgroup is readable at ``/proc/<pid>/cgroup``, which is *not* a
prohibited entry, and ``name_to_handle_at(2)`` on the cgroup directory yields the same 64-bit
kernfs id the kernel put in the netlink attribute. Socket and process therefore meet in
cgroup-id space and procfs's per-process descriptor tables are never opened.

Precision limit, stated plainly
-------------------------------
cgroup membership is one-to-many. This module attributes a socket to a *cgroup*, and from
there to the *set* of candidate PIDs in that cgroup. Where that set contains exactly one
harness process the attribution is unambiguous; where it contains several, the result is
reported as ambiguous with the full candidate set. It is never narrowed by guessing. A
systemd user scope containing a shell, its editor and three build tools is the normal case
on a developer workstation, so ambiguity is expected rather than exceptional.

Classification boundary
-----------------------
No DNS resolution of the destination, no TLS handshake inspection, no packet payload access.
Destination addresses are matched against a committed, versioned range artefact
(``data/inference_providers.json``). Matching is tiered: a ``dedicated`` or ``loopback``
range identifies a provider on address and port alone; a ``shared`` range (Cloudflare, GCP
and Google edge space, which front OpenAI and Vertex respectively and also front most of the
public internet) is a necessary but insufficient signal and requires corroboration from a
classified harness process in the same cgroup. An address matching nothing is ``unknown``.
It is never attributed to the nearest provider.
"""
from __future__ import annotations

import ctypes
import ctypes.util
import ipaddress
import json
import os
import socket
import struct
from pathlib import Path
from typing import Any, Dict, FrozenSet, Iterable, Iterator, List, NamedTuple, Optional, Sequence, Set, Tuple, Union

__all__ = [
    "PROC_ENTRIES_READ_BY_NETWORK_MODULE",
    "DEFAULT_PROVIDER_ARTEFACT",
    "InferenceProviderRanges",
    "ProviderRange",
    "Provider",
    "SocketRecord",
    "CgroupResolver",
    "NetlinkSockDiag",
    "SocketClassification",
    "SocketDetector",
    "NetlinkUnavailable",
]


# --------------------------------------------------------------------------------------
# Structural declaration of this module's procfs surface.
#
# This is the allow-list, not a deny-list. Tests assert equality against this frozenset and
# assert its intersection with proc.PROHIBITED_PROC_ENTRIES is empty. Adding an entry here
# is therefore a visible, reviewable act rather than an incidental import.
# --------------------------------------------------------------------------------------
PROC_ENTRIES_READ_BY_NETWORK_MODULE: FrozenSet[str] = frozenset({"cgroup"})

DEFAULT_PROVIDER_ARTEFACT = Path(__file__).resolve().parent / "data" / "inference_providers.json"

# --------------------------------------------------------------------------------------
# The closed set of identifiers this module may ever emit, frozen IN CODE.
#
# This deliberately duplicates the endpoint names in the JSON artefact. If the allow-list
# were read from the artefact alone, the guard would be its own source of truth: adding a
# provider to the JSON would silently widen the emit surface with no code change and no test
# movement. Loading now cross-checks the two, so a new provider requires editing this
# constant -- a visible, reviewable act that shows up in a diff.
# --------------------------------------------------------------------------------------
ALLOWED_INFERENCE_ENDPOINTS: FrozenSet[str] = frozenset(
    {
        "api.anthropic.com",
        "api.openai.com",
        "aiplatform.googleapis.com",
        "generativelanguage.googleapis.com",
        "ollama.localhost",
        "vllm.localhost",
    }
)

# Status of the cgroup attribution oracle. Never degrade silently: a host where the oracle is
# unavailable falls back to dedicated/loopback ranges only, which is a materially different
# false-positive profile, and the caller has to be able to see that it happened.
ORACLE_AVAILABLE = "available"
ORACLE_NO_ATTRIBUTE = "unavailable_no_cgroup_attribute"
ORACLE_ROOT_ONLY = "unavailable_root_cgroup_only"

# Attribution tiers. A shared range alone never yields an attribution.
ATTRIBUTION_TIERS: FrozenSet[str] = frozenset({"dedicated", "loopback", "shared"})
SELF_SUFFICIENT_TIERS: FrozenSet[str] = frozenset({"dedicated", "loopback"})

# netlink / sock_diag constants (linux/sock_diag.h, linux/inet_diag.h)
NETLINK_SOCK_DIAG = 4
SOCK_DIAG_BY_FAMILY = 20
NLMSG_ERROR = 2
NLMSG_DONE = 3
NLM_F_REQUEST = 0x001
NLM_F_DUMP = 0x300

INET_DIAG_INFO = 2
INET_DIAG_CGROUP_ID = 21

TCP_ESTABLISHED = 1

# struct inet_diag_msg is 72 bytes: u8 family/state/timer/retrans, inet_diag_sockid (48),
# then u32 expires/rqueue/wqueue/uid/inode. Netlink attributes begin immediately after.
_INET_DIAG_MSG_LEN = 72
_SOCKID_OFFSET = 4
_DST_OFFSET = _SOCKID_OFFSET + 4 + 16  # after sport/dport and src[4]
_UID_OFFSET = 64
_INODE_OFFSET = 68

# struct tcp_info: tcpi_bytes_sent is a __u64 at byte offset 200 (kernel >= 4.19).
# The struct only ever grows by appending, so a length guard is sufficient to stay correct
# on kernels that predate the field.
_TCPI_BYTES_SENT_OFFSET = 200
_TCPI_BYTES_ACKED_OFFSET = 120

AT_FDCWD = -100


class NetlinkUnavailable(RuntimeError):
    """Raised when NETLINK_SOCK_DIAG cannot be opened or refuses the dump request.

    This is the stop-and-report signal for this card: if sock_diag is unavailable there is
    no fd-free correlation path, and the correct response is to escalate rather than to fall
    back to the per-process descriptor tables the prohibited set covers.
    """


# --------------------------------------------------------------------------------------
# Provider range artefact
# --------------------------------------------------------------------------------------
class ProviderRange(NamedTuple):
    network: Union[ipaddress.IPv4Network, ipaddress.IPv6Network]
    attribution: str


class Provider(NamedTuple):
    id: str
    endpoint: str
    kind: str
    ports: FrozenSet[int]
    ranges: Tuple[ProviderRange, ...]


class InferenceProviderRanges:
    """Loader and matcher for the committed provider-range artefact."""

    def __init__(self, providers: Sequence[Provider], list_version: str, generated: str) -> None:
        self.providers: Tuple[Provider, ...] = tuple(providers)
        self.list_version = list_version
        self.generated = generated

    # -- construction ------------------------------------------------------------------
    @classmethod
    def load(cls, path: Union[str, Path, None] = None) -> "InferenceProviderRanges":
        artefact = Path(path) if path is not None else DEFAULT_PROVIDER_ARTEFACT
        with open(artefact, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
        return cls.from_dict(raw)

    @classmethod
    def from_dict(cls, raw: Dict[str, Any]) -> "InferenceProviderRanges":
        providers: List[Provider] = []
        for entry in raw.get("providers", []):
            ranges: List[ProviderRange] = []
            for r in entry.get("ranges", []):
                tier = r["attribution"]
                if tier not in ATTRIBUTION_TIERS:
                    raise ValueError(
                        f"provider {entry.get('id')!r} range {r.get('cidr')!r} has unknown "
                        f"attribution tier {tier!r}; expected one of {sorted(ATTRIBUTION_TIERS)}"
                    )
                ranges.append(ProviderRange(ipaddress.ip_network(r["cidr"]), tier))
            kind = entry.get("kind", "inference")
            if kind == "inference" and entry["endpoint"] not in ALLOWED_INFERENCE_ENDPOINTS:
                raise ValueError(
                    f"provider {entry['id']!r} declares inference endpoint "
                    f"{entry['endpoint']!r}, which is absent from ALLOWED_INFERENCE_ENDPOINTS "
                    "in network.py. The artefact cannot widen the emit surface on its own: add "
                    "the identifier to the frozen code constant first."
                )
            providers.append(
                Provider(
                    id=entry["id"],
                    endpoint=entry["endpoint"],
                    kind=kind,
                    ports=frozenset(int(p) for p in entry.get("ports", [])),
                    ranges=tuple(ranges),
                )
            )
        return cls(
            providers=providers,
            list_version=raw.get("list_version", "unknown"),
            generated=raw.get("generated", "unknown"),
        )

    # -- query -------------------------------------------------------------------------
    @property
    def inference_endpoints(self) -> FrozenSet[str]:
        """The closed set of endpoint identifiers this detector is permitted to emit.

        control-plane providers are deliberately excluded: OpenBao is in the artefact so an
        operator can see it was considered, not so a secrets-manager connection can be
        reported as model egress.
        """
        return frozenset(p.endpoint for p in self.providers if p.kind == "inference")

    def match(self, dst_ip: str, dst_port: int) -> Optional[Tuple[Provider, str]]:
        """Return (provider, attribution tier) for the first matching range, else None.

        Matching requires BOTH the address to fall inside a declared range AND the port to be
        one the provider declares. Port is part of the key because loopback inference
        runtimes are distinguished from each other by port alone.
        """
        try:
            addr = ipaddress.ip_address(dst_ip)
        except ValueError:
            return None
        best: Optional[Tuple[Provider, str, int]] = None
        for provider in self.providers:
            if provider.ports and dst_port not in provider.ports:
                continue
            for prange in provider.ranges:
                if addr.version != prange.network.version:
                    continue
                if addr in prange.network:
                    # Prefer the most specific prefix, so a dedicated /23 wins over a
                    # shared /13 that happens to contain it.
                    score = prange.network.prefixlen
                    if best is None or score > best[2]:
                        best = (provider, prange.attribution, score)
        if best is None:
            return None
        return best[0], best[1]


# --------------------------------------------------------------------------------------
# cgroup id bridge
# --------------------------------------------------------------------------------------
class _FileHandle(ctypes.Structure):
    _fields_ = [
        ("handle_bytes", ctypes.c_uint),
        ("handle_type", ctypes.c_int),
        ("f_handle", ctypes.c_ubyte * 128),
    ]


class CgroupResolver:
    """Maps process ids to kernel cgroup ids without touching any prohibited procfs entry.

    Reads exactly one procfs entry per pid: ``/proc/<pid>/cgroup``. That name is absent from
    :data:`proc.PROHIBITED_PROC_ENTRIES` and is already read elsewhere in the sensor by
    ``cgroups.CgroupV2Reader``.
    """

    def __init__(
        self,
        proc_root: Union[str, Path] = "/proc",
        cgroup_root: Union[str, Path] = "/sys/fs/cgroup",
    ) -> None:
        self.proc_root = Path(proc_root)
        self.cgroup_root = Path(cgroup_root)
        self._libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        self._cache: Dict[str, Optional[int]] = {}

    def cgroup_path_for_pid(self, pid: int) -> Optional[Path]:
        """Read /proc/<pid>/cgroup and return the unified-hierarchy directory."""
        cgroup_file = self.proc_root / str(pid) / "cgroup"
        try:
            with open(cgroup_file, "r", encoding="utf-8") as handle:
                content = handle.read()
        except (FileNotFoundError, ProcessLookupError, PermissionError, NotADirectoryError, OSError):
            return None
        for line in content.splitlines():
            line = line.strip()
            if not line.startswith("0::"):
                continue
            rel = line[3:].lstrip("/")
            candidate = self.cgroup_root / rel if rel else self.cgroup_root
            return candidate
        return None

    def cgroup_id_for_path(self, path: Union[str, Path]) -> Optional[int]:
        """Resolve a cgroup directory to its kernel cgroup id via name_to_handle_at(2).

        cgroupfs file handles are the kernfs node id, which is exactly the value the kernel
        reports in INET_DIAG_CGROUP_ID. The first 8 bytes of the handle are that id.
        """
        key = str(path)
        if key in self._cache:
            return self._cache[key]
        handle = _FileHandle()
        handle.handle_bytes = 128
        mount_id = ctypes.c_int()
        rc = self._libc.name_to_handle_at(
            ctypes.c_int(AT_FDCWD),
            key.encode("utf-8"),
            ctypes.byref(handle),
            ctypes.byref(mount_id),
            ctypes.c_int(0),
        )
        result: Optional[int] = None
        if rc == 0 and handle.handle_bytes >= 8:
            raw = bytes(handle.f_handle[: handle.handle_bytes])
            result = struct.unpack_from("=Q", raw, 0)[0]
        self._cache[key] = result
        return result

    def cgroup_id_for_pid(self, pid: int) -> Optional[int]:
        path = self.cgroup_path_for_pid(pid)
        if path is None:
            return None
        return self.cgroup_id_for_path(path)

    def build_cgroup_index(self, pids: Iterable[int]) -> Dict[int, Set[int]]:
        """Return {cgroup_id: {pid, ...}} for the supplied candidate pids."""
        index: Dict[int, Set[int]] = {}
        for pid in pids:
            cgid = self.cgroup_id_for_pid(pid)
            if cgid is None:
                continue
            index.setdefault(cgid, set()).add(pid)
        return index


# --------------------------------------------------------------------------------------
# netlink sock_diag client
# --------------------------------------------------------------------------------------
class SocketRecord(NamedTuple):
    family: int
    state: int
    src_port: int
    dst_port: int
    dst_ip: str
    uid: int
    inode: int
    cgroup_id: Optional[int]
    bytes_sent: int


class NetlinkSockDiag:
    """Minimal pure-stdlib NETLINK_SOCK_DIAG client.

    Deliberately does not shell out to ``ss``: ``ss -p`` resolves process names by scanning
    /proc/<pid>/fd, and a subprocess boundary would put the prohibited read one hop away
    from anything this repository's tests can see.
    """

    def __init__(self, recv_size: int = 262144, timeout_s: float = 5.0) -> None:
        self.recv_size = recv_size
        self.timeout_s = timeout_s

    def _request(self, family: int) -> bytes:
        ext = 1 << (INET_DIAG_INFO - 1)  # CGROUP_ID needs no ext bit; idiag_ext is a u8.
        body = struct.pack("=BBBBI", family, socket.IPPROTO_TCP, ext, 0, 0xFFFFFFFF)
        body += b"\x00" * 48  # zeroed inet_diag_sockid == match all
        header = struct.pack(
            "=IHHII", 16 + len(body), SOCK_DIAG_BY_FAMILY, NLM_F_REQUEST | NLM_F_DUMP, 1, 0
        )
        return header + body

    def dump(
        self,
        families: Sequence[int] = (socket.AF_INET, socket.AF_INET6),
        restrict_to_cgroups: Optional[Set[int]] = None,
    ) -> List[SocketRecord]:
        """Dump sockets, optionally discarding everything outside the given cgroups.

        ``restrict_to_cgroups`` is a privacy control, not an optimisation, and it exists
        because this module's observation aperture is genuinely WIDER than the descriptor-
        scanning approach it replaces. A sock_diag dump is host-wide: without a restriction
        it returns the 5-tuples of every socket on the machine -- the operator's browser,
        bank, VPN and employer's internal services -- where reading one process's descriptor
        table only ever saw that one process. "We avoided the prohibited entry" would be true
        in the letter and misleading in spirit if that change went unmentioned and
        unmitigated.

        When the restriction is supplied, a non-matching record is discarded inside the parse
        loop BEFORE its destination address is decoded into a string, so unrelated
        destinations are never materialised in this process at all.
        """
        records: List[SocketRecord] = []
        for family in families:
            records.extend(self._dump_family(family, restrict_to_cgroups))
        return records

    def _dump_family(
        self, family: int, restrict_to_cgroups: Optional[Set[int]] = None
    ) -> Iterator[SocketRecord]:
        try:
            sock = socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM, NETLINK_SOCK_DIAG)
        except OSError as exc:  # pragma: no cover - requires a kernel without sock_diag
            raise NetlinkUnavailable(
                "NETLINK_SOCK_DIAG unavailable; there is no descriptor-free socket-to-process "
                "correlation path on this host. Escalate per SLCD-P4-2 rather than falling back "
                f"to any procfs entry named in PROHIBITED_PROC_ENTRIES. Underlying error: {exc}"
            ) from exc
        try:
            sock.settimeout(self.timeout_s)
            sock.sendall(self._request(family))
            while True:
                try:
                    buf = sock.recv(self.recv_size)
                except socket.timeout:  # pragma: no cover - slow kernel
                    return
                if not buf:
                    return
                offset = 0
                while offset + 16 <= len(buf):
                    length, msg_type, _flags, _seq, _pid = struct.unpack_from("=IHHII", buf, offset)
                    if length < 16:
                        return
                    if msg_type == NLMSG_DONE:
                        return
                    if msg_type == NLMSG_ERROR:
                        (errno_val,) = struct.unpack_from("=i", buf, offset + 16)
                        if errno_val != 0:
                            raise NetlinkUnavailable(
                                f"sock_diag dump for family {family} refused with errno "
                                f"{abs(errno_val)}. Escalate per SLCD-P4-2."
                            )
                        return
                    body = buf[offset + 16 : offset + length]
                    record = self._parse_msg(family, body, restrict_to_cgroups)
                    if record is not None:
                        yield record
                    offset += (length + 3) & ~3
        finally:
            sock.close()

    @staticmethod
    def _parse_msg(
        family: int, body: bytes, restrict_to_cgroups: Optional[Set[int]] = None
    ) -> Optional[SocketRecord]:
        if len(body) < _INET_DIAG_MSG_LEN:
            return None
        state = body[1]
        src_port, dst_port = struct.unpack_from("!HH", body, _SOCKID_OFFSET)
        (uid,) = struct.unpack_from("=I", body, _UID_OFFSET)
        (inode,) = struct.unpack_from("=I", body, _INODE_OFFSET)

        cgroup_id: Optional[int] = None
        bytes_sent = 0
        attr_offset = _INET_DIAG_MSG_LEN
        while attr_offset + 4 <= len(body):
            attr_len, attr_type = struct.unpack_from("=HH", body, attr_offset)
            if attr_len < 4:
                break
            payload = body[attr_offset + 4 : attr_offset + attr_len]
            if attr_type == INET_DIAG_CGROUP_ID and len(payload) >= 8:
                (cgroup_id,) = struct.unpack_from("=Q", payload, 0)
            elif attr_type == INET_DIAG_INFO:
                if len(payload) >= _TCPI_BYTES_SENT_OFFSET + 8:
                    (bytes_sent,) = struct.unpack_from("=Q", payload, _TCPI_BYTES_SENT_OFFSET)
                elif len(payload) >= _TCPI_BYTES_ACKED_OFFSET + 8:
                    # Pre-4.19 kernels lack tcpi_bytes_sent. bytes_acked understates egress
                    # by the in-flight window; it never overstates it.
                    (bytes_sent,) = struct.unpack_from("=Q", payload, _TCPI_BYTES_ACKED_OFFSET)
            attr_offset += (attr_len + 3) & ~3

        # Privacy gate. Discard before the destination address is turned into a string, so a
        # socket belonging to the operator's browser is never materialised in this process.
        if restrict_to_cgroups is not None and cgroup_id not in restrict_to_cgroups:
            return None

        raw_dst = body[_DST_OFFSET : _DST_OFFSET + 16]
        if family == socket.AF_INET:
            dst_ip = socket.inet_ntop(socket.AF_INET, raw_dst[:4])
        else:
            dst_ip = socket.inet_ntop(socket.AF_INET6, raw_dst)

        return SocketRecord(
            family=family,
            state=state,
            src_port=src_port,
            dst_port=dst_port,
            dst_ip=dst_ip,
            uid=uid,
            inode=inode,
            cgroup_id=cgroup_id,
            bytes_sent=bytes_sent,
        )


# --------------------------------------------------------------------------------------
# Detector
# --------------------------------------------------------------------------------------
class SocketClassification(NamedTuple):
    """Internal classification result.

    ``endpoint`` is None for verdict ``unknown``. ``dst_ip`` is retained here for operator
    diagnostics only and is NEVER carried into the exported telemetry record -- see
    :meth:`SocketDetector.to_network_info`, which projects to exactly the two P1-1 fields.
    """

    verdict: str  # "inference" | "control-plane" | "unknown"
    provider_id: Optional[str]
    endpoint: Optional[str]
    attribution: Optional[str]
    corroborated: bool
    ambiguous: bool
    candidate_pids: Tuple[int, ...]
    egress_bytes: int
    dst_ip: str
    dst_port: int
    reason: str


class SocketDetector:
    """Correlates established outbound sockets to harness processes, fd-free.

    ``harness_pids`` is the set of process ids the upstream classifier already identified as
    coding-agent harnesses. Supplying it is what turns a shared-range match into an
    attribution; omit it and every shared-range socket classifies ``unknown`` by design.
    """

    def __init__(
        self,
        ranges: Optional[InferenceProviderRanges] = None,
        diag: Optional[NetlinkSockDiag] = None,
        cgroups: Optional[CgroupResolver] = None,
    ) -> None:
        self.ranges = ranges if ranges is not None else InferenceProviderRanges.load()
        self.diag = diag if diag is not None else NetlinkSockDiag()
        self.cgroups = cgroups if cgroups is not None else CgroupResolver()
        self.last_oracle_status: str = ORACLE_NO_ATTRIBUTE

    # -- classification ----------------------------------------------------------------
    def classify(
        self,
        record: SocketRecord,
        harness_cgroup_index: Optional[Dict[int, Set[int]]] = None,
    ) -> SocketClassification:
        index = harness_cgroup_index or {}
        candidates = tuple(sorted(index.get(record.cgroup_id, set()))) if record.cgroup_id else ()
        corroborated = bool(candidates)

        matched = self.ranges.match(record.dst_ip, record.dst_port)
        if matched is None:
            # No range matched. This is where a naive implementation guesses the nearest
            # provider; this one refuses to.
            return SocketClassification(
                verdict="unknown",
                provider_id=None,
                endpoint=None,
                attribution=None,
                corroborated=corroborated,
                ambiguous=len(candidates) > 1,
                candidate_pids=candidates,
                egress_bytes=record.bytes_sent,
                dst_ip=record.dst_ip,
                dst_port=record.dst_port,
                reason="no declared range contains this destination",
            )

        provider, tier = matched

        if provider.kind != "inference":
            return SocketClassification(
                verdict="control-plane",
                provider_id=provider.id,
                endpoint=None,
                attribution=tier,
                corroborated=corroborated,
                ambiguous=len(candidates) > 1,
                candidate_pids=candidates,
                egress_bytes=record.bytes_sent,
                dst_ip=record.dst_ip,
                dst_port=record.dst_port,
                reason=f"{provider.id} is kind=control-plane and is never inference egress",
            )

        if tier in SELF_SUFFICIENT_TIERS:
            return SocketClassification(
                verdict="inference",
                provider_id=provider.id,
                endpoint=provider.endpoint,
                attribution=tier,
                corroborated=corroborated,
                ambiguous=len(candidates) > 1,
                candidate_pids=candidates,
                egress_bytes=record.bytes_sent,
                dst_ip=record.dst_ip,
                dst_port=record.dst_port,
                reason=f"{tier} range is exclusive to {provider.id}",
            )

        if not corroborated:
            return SocketClassification(
                verdict="unknown",
                provider_id=None,
                endpoint=None,
                attribution=tier,
                corroborated=False,
                ambiguous=False,
                candidate_pids=(),
                egress_bytes=record.bytes_sent,
                dst_ip=record.dst_ip,
                dst_port=record.dst_port,
                reason=(
                    f"destination is inside {provider.id} shared infrastructure but no harness "
                    "process shares the socket's cgroup; shared space is not sufficient"
                ),
            )

        return SocketClassification(
            verdict="inference",
            provider_id=provider.id,
            endpoint=provider.endpoint,
            attribution=tier,
            corroborated=True,
            ambiguous=len(candidates) > 1,
            candidate_pids=candidates,
            egress_bytes=record.bytes_sent,
            dst_ip=record.dst_ip,
            dst_port=record.dst_port,
            reason=f"shared range corroborated by harness pid(s) {list(candidates)} in the same cgroup",
        )

    # -- collection --------------------------------------------------------------------
    def probe_cgroup_oracle(self, index: Dict[int, Set[int]]) -> str:
        """Report whether cgroup attribution can discriminate on this host.

        Three ways it silently cannot, each of which degrades the detector to
        dedicated/loopback ranges only -- a materially worse false-positive profile that the
        caller must be able to see rather than infer:

        - the kernel predates INET_DIAG_CGROUP_ID (< 5.5), so no attribute arrives;
        - a cgroup v1 net_cls/net_prio controller is mounted, which disables socket cgroup
          association, so every socket reports the root cgroup and "matches" everything;
        - no harness pid resolved to a cgroup at all.
        """
        if not index:
            return ORACLE_NO_ATTRIBUTE
        root = self.cgroups.cgroup_id_for_path(self.cgroups.cgroup_root)
        if root is not None and set(index) == {root}:
            return ORACLE_ROOT_ONLY
        return ORACLE_AVAILABLE

    def detect(
        self,
        harness_pids: Optional[Iterable[int]] = None,
        established_only: bool = True,
        restrict_to_harness_cgroups: bool = False,
    ) -> List[SocketClassification]:
        """Classify established outbound sockets.

        ``restrict_to_harness_cgroups`` narrows the netlink dump to the harness cgroups only,
        so unrelated destinations on the host are discarded before their addresses are
        decoded. It defaults to False because the false-positive measurement needs the full
        table; production collection should set it True. See NetlinkSockDiag.dump.
        """
        pids = list(harness_pids or [])
        index = self.cgroups.build_cgroup_index(pids) if pids else {}
        self.last_oracle_status = self.probe_cgroup_oracle(index)
        restriction = set(index) if (restrict_to_harness_cgroups and index) else None
        out: List[SocketClassification] = []
        for record in self.diag.dump(restrict_to_cgroups=restriction):
            if established_only and record.state != TCP_ESTABLISHED:
                continue
            out.append(self.classify(record, index))
        return out

    def detect_inference(self, harness_pids: Optional[Iterable[int]] = None) -> List[SocketClassification]:
        return [c for c in self.detect(harness_pids) if c.verdict == "inference"]

    # -- export ------------------------------------------------------------------------
    def to_network_info(self, classification: SocketClassification) -> Dict[str, Any]:
        """Project a classification onto P1-1's frozen network.* schema.

        Exactly two keys leave this function. The endpoint is checked for membership in the
        artefact's inference-endpoint set rather than merely validated against
        INFERENCE_ENDPOINT_REGEX -- that regex is ``^[a-zA-Z0-9.-]{1,128}$``, which a raw
        IPv4 literal also satisfies, so it would not have caught an address leaking into the
        field under a name that still looked correct.
        """
        if classification.verdict != "inference" or classification.endpoint is None:
            raise ValueError(
                "refusing to export a non-inference classification as network telemetry: "
                f"verdict={classification.verdict!r} reason={classification.reason!r}"
            )
        allowed = self.ranges.inference_endpoints
        if classification.endpoint not in allowed:
            raise ValueError(
                f"endpoint {classification.endpoint!r} is not a member of the committed "
                f"provider artefact's inference endpoint set {sorted(allowed)!r}; refusing to "
                "emit. This is the structural allow-list, not the field regex."
            )
        return {
            "inference_endpoint": classification.endpoint,
            "egress_bytes": int(classification.egress_bytes),
        }

    def aggregate_network_info(
        self, classifications: Sequence[SocketClassification]
    ) -> Optional[Dict[str, Any]]:
        """Collapse several sockets for one endpoint into a single network.* record."""
        inference = [c for c in classifications if c.verdict == "inference" and c.endpoint]
        if not inference:
            return None
        totals: Dict[str, int] = {}
        for c in inference:
            totals[c.endpoint] = totals.get(c.endpoint, 0) + int(c.egress_bytes)
        endpoint = max(totals.items(), key=lambda kv: (kv[1], kv[0]))[0]
        merged = SocketClassification(
            verdict="inference",
            provider_id=None,
            endpoint=endpoint,
            attribution=None,
            corroborated=True,
            ambiguous=False,
            candidate_pids=(),
            egress_bytes=totals[endpoint],
            dst_ip="",
            dst_port=0,
            reason="aggregate",
        )
        return self.to_network_info(merged)
