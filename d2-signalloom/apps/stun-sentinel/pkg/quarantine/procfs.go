// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package quarantine

import (
	"bufio"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// DefaultProcRoot is the conventional Linux procfs mount.
const DefaultProcRoot = "/proc"

// ParseMaps parses /proc/<pid>/maps for a target process.
func ParseMaps(pid int, procRoot string) ([]MemoryRegion, error) {
	if procRoot == "" {
		procRoot = DefaultProcRoot
	}
	mapsPath := filepath.Join(procRoot, strconv.Itoa(pid), "maps")
	f, err := os.Open(mapsPath)
	if err != nil {
		return nil, fmt.Errorf("open maps: %w", err)
	}
	defer f.Close()
	return ParseMapsFromReader(f)
}

// ParseMapsFromReader parses virtual memory regions from an io.Reader formatted like /proc/<pid>/maps.
func ParseMapsFromReader(r io.Reader) ([]MemoryRegion, error) {
	var regions []MemoryRegion
	scanner := bufio.NewScanner(r)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}

		addrRange := strings.Split(fields[0], "-")
		if len(addrRange) != 2 {
			continue
		}

		startUint, err := strconv.ParseUint(addrRange[0], 16, 64)
		if err != nil {
			continue
		}
		endUint, err := strconv.ParseUint(addrRange[1], 16, 64)
		if err != nil {
			continue
		}

		perms := fields[1]
		offset, _ := strconv.ParseUint(fields[2], 16, 64)
		dev := fields[3]
		inode, _ := strconv.ParseUint(fields[4], 10, 64)

		var pathname string
		if len(fields) >= 6 {
			pathname = strings.Join(fields[5:], " ")
		}

		isAnon := dev == "00:00" || inode == 0 || pathname == "" ||
			strings.HasPrefix(pathname, "[heap]") ||
			strings.HasPrefix(pathname, "[stack]") ||
			strings.HasPrefix(pathname, "[anon]")

		isWritable := strings.Contains(perms, "w")

		regions = append(regions, MemoryRegion{
			StartAddr:   "0x" + addrRange[0],
			EndAddr:     "0x" + addrRange[1],
			StartUint:   startUint,
			EndUint:     endUint,
			Perms:       perms,
			Offset:      offset,
			Dev:         dev,
			Inode:       inode,
			Pathname:    pathname,
			IsAnonymous: isAnon,
			IsWritable:  isWritable,
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read maps: %w", err)
	}
	return regions, nil
}

// ParseFDs reads the file descriptors of a process from /proc/<pid>/fd.
func ParseFDs(pid int, procRoot string) ([]FDInfo, error) {
	if procRoot == "" {
		procRoot = DefaultProcRoot
	}
	fdDir := filepath.Join(procRoot, strconv.Itoa(pid), "fd")
	entries, err := os.ReadDir(fdDir)
	if err != nil {
		return nil, fmt.Errorf("read fd dir: %w", err)
	}

	var fds []FDInfo
	for _, entry := range entries {
		fdNum, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}

		fdLinkPath := filepath.Join(fdDir, entry.Name())
		target, err := os.Readlink(fdLinkPath)
		if err != nil {
			target = "unknown"
		}

		kind := classifyFDKind(target)
		var inode uint64
		if kind == "socket" || kind == "pipe" {
			inode = parseInodeFromBracket(target)
		}

		info := FDInfo{
			FD:     fdNum,
			Target: target,
			Kind:   kind,
			Inode:  inode,
		}

		// Read fdinfo if available
		fdinfoPath := filepath.Join(procRoot, strconv.Itoa(pid), "fdinfo", entry.Name())
		if pos, flags, ino, err := parseFDInfo(fdinfoPath); err == nil {
			info.Pos = pos
			info.Flags = flags
			if info.Inode == 0 && ino > 0 {
				info.Inode = ino
			}
		}

		fds = append(fds, info)
	}
	return fds, nil
}

func classifyFDKind(target string) string {
	switch {
	case strings.HasPrefix(target, "socket:["):
		return "socket"
	case strings.HasPrefix(target, "pipe:["):
		return "pipe"
	case strings.HasPrefix(target, "anon_inode:"):
		return "anon_inode"
	case strings.HasPrefix(target, "/dev/"):
		return "device"
	case strings.HasPrefix(target, "/"):
		return "file"
	default:
		return "unknown"
	}
}

func parseInodeFromBracket(target string) uint64 {
	start := strings.Index(target, "[")
	end := strings.Index(target, "]")
	if start != -1 && end != -1 && end > start+1 {
		ino, _ := strconv.ParseUint(target[start+1:end], 10, 64)
		return ino
	}
	return 0
}

func parseFDInfo(path string) (pos int64, flags string, inode uint64, err error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, "", 0, err
	}
	for _, line := range strings.Split(string(data), "\n") {
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])
		switch key {
		case "pos":
			pos, _ = strconv.ParseInt(val, 10, 64)
		case "flags":
			flags = val
		case "ino":
			inode, _ = strconv.ParseUint(val, 10, 64)
		}
	}
	return pos, flags, inode, nil
}

// ParseLocks extracts all file locks held by the given PID from /proc/locks and /proc/<pid>/fdinfo.
func ParseLocks(pid int, procRoot string, fds []FDInfo) ([]LockRecord, error) {
	if procRoot == "" {
		procRoot = DefaultProcRoot
	}

	var records []LockRecord
	seenInodes := make(map[uint64]bool)

	inodeToFD := make(map[uint64]FDInfo)
	for _, fd := range fds {
		if fd.Inode > 0 {
			inodeToFD[fd.Inode] = fd
		}
	}

	// 1. Parse /proc/locks
	locksPath := filepath.Join(procRoot, "locks")
	if f, err := os.Open(locksPath); err == nil {
		if recs, err := ParseLocksFromReaderWithInodes(f, pid, inodeToFD); err == nil {
			for _, r := range recs {
				records = append(records, r)
				if r.Inode > 0 {
					seenInodes[r.Inode] = true
				}
			}
		}
		f.Close()
	}

	// 2. Parse /proc/<pid>/fdinfo/<fd> for lock: lines
	for _, fd := range fds {
		if seenInodes[fd.Inode] {
			continue
		}

		fdinfoPath := filepath.Join(procRoot, strconv.Itoa(pid), "fdinfo", strconv.Itoa(fd.FD))
		if data, err := os.ReadFile(fdinfoPath); err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				line = strings.TrimSpace(line)
				if strings.HasPrefix(line, "lock:") {
					lockFields := strings.Fields(strings.TrimPrefix(line, "lock:"))
					if len(lockFields) >= 3 {
						lockType := lockFields[1]
						lockMode := "WRITE"
						if len(lockFields) >= 4 {
							lockMode = lockFields[3]
						}
						records = append(records, LockRecord{
							PID:      pid,
							FD:       fd.FD,
							LockType: lockType,
							LockMode: lockMode,
							Path:     fd.Target,
							Inode:    fd.Inode,
						})
						if fd.Inode > 0 {
							seenInodes[fd.Inode] = true
						}
					}
				}
			}
		}
	}

	// Correlate with FDs to populate file paths
	for i := range records {
		if records[i].Path == "" && records[i].Inode > 0 {
			if fd, found := inodeToFD[records[i].Inode]; found {
				records[i].FD = fd.FD
				records[i].Path = fd.Target
			}
		}
	}

	return records, nil
}

// ParseLocksFromReader parses /proc/locks records for a given PID or matching open inodes.
func ParseLocksFromReader(r io.Reader, pid int) ([]LockRecord, error) {
	return ParseLocksFromReaderWithInodes(r, pid, nil)
}

// ParseLocksFromReaderWithInodes parses /proc/locks records for a given PID and set of target file inodes.
func ParseLocksFromReaderWithInodes(r io.Reader, pid int, targetInodes map[uint64]FDInfo) ([]LockRecord, error) {
	var records []LockRecord
	scanner := bufio.NewScanner(r)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 6 {
			continue
		}

		// Example fields:
		// 0: "1:" (ordinal)
		// 1: "POSIX" / "FLOCK" / "OFD" / "OFDLCK"
		// 2: "ADVISORY" / "MANDATORY"
		// 3: "WRITE" / "READ"
		// 4: PID
		// 5: "major:minor:inode" (e.g. "fd:00:97704115")
		// 6: start (e.g. "0")
		// 7: end (e.g. "EOF" or "1024")

		lockPid, _ := strconv.Atoi(fields[4])
		devInode := fields[5]

		var inode uint64
		var devStr string
		devInodeParts := strings.Split(devInode, ":")
		if len(devInodeParts) >= 3 {
			devStr = devInodeParts[0] + ":" + devInodeParts[1]
			inode, _ = strconv.ParseUint(devInodeParts[2], 10, 64)
		} else if len(devInodeParts) == 2 {
			devStr = devInodeParts[0]
			inode, _ = strconv.ParseUint(devInodeParts[1], 10, 64)
		}

		pidMatches := lockPid > 0 && lockPid == pid
		_, inodeMatches := targetInodes[inode]
		if !pidMatches && !inodeMatches {
			continue
		}

		lockType := fields[1]
		lockMode := fields[3]

		var start int64
		if len(fields) >= 7 {
			start, _ = strconv.ParseInt(fields[6], 10, 64)
		}
		var end int64 = -1
		if len(fields) >= 8 && fields[7] != "EOF" {
			end, _ = strconv.ParseInt(fields[7], 10, 64)
		}

		rec := LockRecord{
			PID:      pid,
			LockType: lockType,
			LockMode: lockMode,
			Start:    start,
			End:      end,
			Device:   devStr,
			Inode:    inode,
		}
		if fd, found := targetInodes[inode]; found {
			rec.FD = fd.FD
			rec.Path = fd.Target
		}

		records = append(records, rec)
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read locks: %w", err)
	}
	return records, nil
}

// ParseSockets inspects open socket file descriptors and parses /proc/<pid>/net/tcp etc.
func ParseSockets(pid int, procRoot string, fds []FDInfo) ([]SocketInfo, error) {
	if procRoot == "" {
		procRoot = DefaultProcRoot
	}

	inodeToFD := make(map[uint64]int)
	for _, fd := range fds {
		if fd.Kind == "socket" && fd.Inode > 0 {
			inodeToFD[fd.Inode] = fd.FD
		}
	}

	if len(inodeToFD) == 0 {
		return []SocketInfo{}, nil
	}

	var results []SocketInfo
	pidStr := strconv.Itoa(pid)

	// Try container network namespace first (/proc/<pid>/net/*), fall back to host (/proc/net/*)
	netFiles := []struct {
		proto string
		rel   string
	}{
		{proto: "tcp", rel: "net/tcp"},
		{proto: "tcp6", rel: "net/tcp6"},
		{proto: "udp", rel: "net/udp"},
		{proto: "udp6", rel: "net/udp6"},
	}

	for _, nf := range netFiles {
		path := filepath.Join(procRoot, pidStr, nf.rel)
		f, err := os.Open(path)
		if err != nil {
			path = filepath.Join(procRoot, nf.rel)
			f, err = os.Open(path)
			if err != nil {
				continue
			}
		}

		socks, err := ParseSocketsFromReader(f, nf.proto, inodeToFD)
		f.Close()
		if err == nil {
			results = append(results, socks...)
		}
	}

	// For sockets not matched in tcp/udp (e.g. unix sockets or transient sockets), include basic descriptor
	matchedInodes := make(map[uint64]bool)
	for _, s := range results {
		matchedInodes[s.Inode] = true
	}
	for inode, fd := range inodeToFD {
		if !matchedInodes[inode] {
			results = append(results, SocketInfo{
				FD:         fd,
				Protocol:   "unknown",
				LocalAddr:  "*",
				RemoteAddr: "*",
				State:      "OPEN",
				Inode:      inode,
			})
		}
	}

	return results, nil
}

// ParseSocketsFromReader parses network table lines (e.g. /proc/net/tcp).
func ParseSocketsFromReader(r io.Reader, proto string, targetInodes map[uint64]int) ([]SocketInfo, error) {
	var socks []SocketInfo
	scanner := bufio.NewScanner(r)

	// First line is header
	if scanner.Scan() {
		_ = scanner.Text()
	}

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 10 {
			continue
		}

		// Field 1: local_address (hex IP:port)
		// Field 2: rem_address (hex IP:port)
		// Field 3: st (hex state)
		// Field 9: inode
		inode, err := strconv.ParseUint(fields[9], 10, 64)
		if err != nil {
			continue
		}

		fd, matched := targetInodes[inode]
		if !matched {
			continue
		}

		localAddr := parseHexAddress(fields[1], strings.HasSuffix(proto, "6"))
		remAddr := parseHexAddress(fields[2], strings.HasSuffix(proto, "6"))
		state := parseTCPState(fields[3])

		socks = append(socks, SocketInfo{
			FD:         fd,
			Protocol:   proto,
			LocalAddr:  localAddr,
			RemoteAddr: remAddr,
			State:      state,
			Inode:      inode,
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read socket table: %w", err)
	}
	return socks, nil
}

func parseHexAddress(hexAddr string, isV6 bool) string {
	parts := strings.Split(hexAddr, ":")
	if len(parts) != 2 {
		return hexAddr
	}

	portUint, err := strconv.ParseUint(parts[1], 16, 16)
	if err != nil {
		return hexAddr
	}
	port := strconv.FormatUint(portUint, 10)

	if isV6 {
		ipBytes, err := hex.DecodeString(parts[0])
		if err != nil || len(ipBytes) != 16 {
			return hexAddr
		}
		// In Linux /proc/net/tcp6, each 32-bit word is little-endian
		var reordered [16]byte
		for i := 0; i < 4; i++ {
			word := binary.LittleEndian.Uint32(ipBytes[i*4 : (i+1)*4])
			binary.BigEndian.PutUint32(reordered[i*4:(i+1)*4], word)
		}
		ip := net.IP(reordered[:])
		return net.JoinHostPort(ip.String(), port)
	}

	// IPv4: 8 hex characters, little-endian 32-bit uint
	val, err := strconv.ParseUint(parts[0], 16, 32)
	if err != nil {
		return hexAddr
	}
	ip := net.IPv4(byte(val), byte(val>>8), byte(val>>16), byte(val>>24))
	return net.JoinHostPort(ip.String(), port)
}

func parseTCPState(stHex string) string {
	switch strings.ToUpper(stHex) {
	case "01":
		return "ESTABLISHED"
	case "02":
		return "SYN_SENT"
	case "03":
		return "SYN_RECV"
	case "04":
		return "FIN_WAIT1"
	case "05":
		return "FIN_WAIT2"
	case "06":
		return "TIME_WAIT"
	case "07":
		return "CLOSE"
	case "08":
		return "CLOSE_WAIT"
	case "09":
		return "LAST_ACK"
	case "0A":
		return "LISTEN"
	case "0B":
		return "CLOSING"
	default:
		return "UNKNOWN(" + stHex + ")"
	}
}

// ParseStatus extracts memory metrics, process state, and PPID from /proc/<pid>/status.
func ParseStatus(pid int, procRoot string) (stats MemoryStatistics, comm string, state string, ppid int, err error) {
	if procRoot == "" {
		procRoot = DefaultProcRoot
	}
	statusPath := filepath.Join(procRoot, strconv.Itoa(pid), "status")
	f, err := os.Open(statusPath)
	if err != nil {
		return stats, "", "", 0, fmt.Errorf("open status: %w", err)
	}
	defer f.Close()
	return ParseStatusFromReader(f)
}

// ParseStatusFromReader parses /proc/<pid>/status content.
func ParseStatusFromReader(r io.Reader) (stats MemoryStatistics, comm string, state string, ppid int, err error) {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])

		switch key {
		case "Name":
			comm = val
		case "State":
			stateFields := strings.Fields(val)
			if len(stateFields) > 0 {
				state = stateFields[0]
			}
		case "PPid":
			ppid, _ = strconv.Atoi(val)
		case "VmSize":
			stats.VMSizeBytes = parseKBToBytes(val)
		case "VmRSS":
			stats.RSSBytes = parseKBToBytes(val)
		case "VmSwap":
			stats.VMSwapBytes = parseKBToBytes(val)
		case "VmData":
			stats.VMDataBytes = parseKBToBytes(val)
		case "VmStk":
			stats.VMStackBytes = parseKBToBytes(val)
		}
	}
	if err := scanner.Err(); err != nil {
		return stats, comm, state, ppid, fmt.Errorf("read status: %w", err)
	}
	return stats, comm, state, ppid, nil
}

func parseKBToBytes(val string) int64 {
	fields := strings.Fields(val)
	if len(fields) > 0 {
		kb, err := strconv.ParseInt(fields[0], 10, 64)
		if err == nil {
			return kb * 1024
		}
	}
	return 0
}

// ParseCmdline reads /proc/<pid>/cmdline.
func ParseCmdline(pid int, procRoot string) ([]string, error) {
	if procRoot == "" {
		procRoot = DefaultProcRoot
	}
	cmdPath := filepath.Join(procRoot, strconv.Itoa(pid), "cmdline")
	data, err := os.ReadFile(cmdPath)
	if err != nil {
		return nil, fmt.Errorf("read cmdline: %w", err)
	}
	if len(data) == 0 {
		return []string{}, nil
	}
	// NUL-delimited strings
	rawParts := strings.Split(string(data), "\x00")
	var parts []string
	for _, p := range rawParts {
		if p != "" {
			parts = append(parts, p)
		}
	}
	return parts, nil
}

// DumpMemoryRegion reads the virtual memory of a process region using process_vm_readv(2)
// or /proc/<pid>/mem pread(2) at region.StartUint up to maxBytes, streaming into out and returning bytes written and sha256 checksum.
func DumpMemoryRegion(pid int, region *MemoryRegion, procRoot string, maxBytes int64, out io.Writer) (int64, string, error) {
	if procRoot == "" {
		procRoot = DefaultProcRoot
	}
	if region.EndUint <= region.StartUint || !strings.Contains(region.Perms, "r") {
		return 0, "", nil
	}

	sizeToRead := int64(region.EndUint - region.StartUint)
	if maxBytes > 0 && sizeToRead > maxBytes {
		sizeToRead = maxBytes
	}

	hasher := sha256.New()
	mw := io.MultiWriter(out, hasher)

	buf := make([]byte, 64*1024) // 64KB chunk buffer
	var totalRead int64
	offset := int64(region.StartUint)

	// Try process_vm_readv first (direct Linux kernel syscall)
	var tryProcMem bool
	for totalRead < sizeToRead {
		chunkSize := int64(len(buf))
		if sizeToRead-totalRead < chunkSize {
			chunkSize = sizeToRead - totalRead
		}

		localIov := []unix.Iovec{{Base: &buf[0], Len: uint64(chunkSize)}}
		remoteIov := []unix.RemoteIovec{{Base: uintptr(offset + totalRead), Len: int(chunkSize)}}

		n, err := unix.ProcessVMReadv(pid, localIov, remoteIov, 0)
		if err == nil && n > 0 {
			if _, wErr := mw.Write(buf[:n]); wErr != nil {
				return totalRead, "", fmt.Errorf("write dump: %w", wErr)
			}
			totalRead += int64(n)
			continue
		}

		// If process_vm_readv failed, fallback to /proc/<pid>/mem
		tryProcMem = true
		break
	}

	if tryProcMem {
		memPath := filepath.Join(procRoot, strconv.Itoa(pid), "mem")
		f, err := os.Open(memPath)
		if err != nil {
			if totalRead > 0 {
				hashStr := "sha256:" + hex.EncodeToString(hasher.Sum(nil))
				return totalRead, hashStr, nil
			}
			return 0, "", fmt.Errorf("open mem: %w", err)
		}
		defer f.Close()

		for totalRead < sizeToRead {
			chunkSize := int64(len(buf))
			if sizeToRead-totalRead < chunkSize {
				chunkSize = sizeToRead - totalRead
			}

			n, rErr := f.ReadAt(buf[:chunkSize], offset+totalRead)
			if n > 0 {
				if _, wErr := mw.Write(buf[:n]); wErr != nil {
					return totalRead, "", fmt.Errorf("write dump: %w", wErr)
				}
				totalRead += int64(n)
			}
			if rErr != nil {
				if rErr == io.EOF || totalRead > 0 {
					break
				}
				// If first chunk errored, try advancing 4KB page
				offset += 4096
				if offset >= int64(region.EndUint) {
					break
				}
			}
		}
	}

	hashStr := "sha256:" + hex.EncodeToString(hasher.Sum(nil))
	return totalRead, hashStr, nil
}
