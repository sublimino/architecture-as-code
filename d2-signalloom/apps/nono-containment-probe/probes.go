package main

import (
	"errors"
	"io"
	"net/http"
	"os"
	"syscall"
	"time"
)

// ProbeResult is the structured output for each containment probe.
type ProbeResult struct {
	Probe            string `json:"probe"`
	Action           string `json:"action"`
	Result           string `json:"result"`
	Errno            string `json:"errno,omitempty"`
	LandlockEnforced bool   `json:"landlock_enforced"`
}

// errnoString returns the syscall errno name if the error wraps one.
func errnoString(err error) string {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		switch errno {
		case syscall.EACCES:
			return "EACCES"
		case syscall.EPERM:
			return "EPERM"
		case syscall.ENOENT:
			return "ENOENT"
		default:
			return errno.Error()
		}
	}
	return ""
}

// isPermissionError returns true if the error is a permission-denied error
// (EACCES or EPERM), which indicates Landlock enforcement.
func isPermissionError(err error) bool {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		return errno == syscall.EACCES || errno == syscall.EPERM
	}
	return os.IsPermission(err)
}

// probeReadShadow attempts to read /etc/shadow. Under Landlock, this should
// return EACCES.
func probeReadShadow() ProbeResult {
	r := ProbeResult{
		Probe:  "read_shadow",
		Action: "read /etc/shadow",
	}

	f, err := os.Open("/etc/shadow")
	if err != nil {
		r.Result = "blocked"
		r.Errno = errnoString(err)
		r.LandlockEnforced = isPermissionError(err)
		return r
	}
	f.Close()
	r.Result = "allowed"
	return r
}

// probeWriteOutside attempts to write to /usr/local/evil. Under Landlock,
// this should return EACCES.
func probeWriteOutside() ProbeResult {
	r := ProbeResult{
		Probe:  "write_outside",
		Action: "write /usr/local/evil",
	}

	f, err := os.Create("/usr/local/evil")
	if err != nil {
		r.Result = "blocked"
		r.Errno = errnoString(err)
		r.LandlockEnforced = isPermissionError(err)
		return r
	}
	f.Close()
	os.Remove("/usr/local/evil") // cleanup if somehow allowed
	r.Result = "allowed"
	return r
}

// probeMetadataExfil attempts an HTTP GET to the cloud metadata endpoint.
// Under Landlock network restrictions, this should be connection-refused.
func probeMetadataExfil() ProbeResult {
	r := ProbeResult{
		Probe:  "metadata_exfil",
		Action: "GET http://169.254.169.254/latest/meta-data/",
	}

	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://169.254.169.254/latest/meta-data/")
	if err != nil {
		r.Result = "blocked"
		r.Errno = "ENETUNREACH"
		r.LandlockEnforced = true
		return r
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	r.Result = "allowed"
	return r
}

// probeWorkspaceRead attempts to read a file inside /workspace. This should
// succeed under Landlock because /workspace is in the allowed path set.
func probeWorkspaceRead(path string) ProbeResult {
	r := ProbeResult{
		Probe:  "workspace_read",
		Action: "read " + path,
	}

	data, err := os.ReadFile(path)
	if err != nil {
		r.Result = "blocked"
		r.Errno = errnoString(err)
		r.LandlockEnforced = isPermissionError(err)
		return r
	}
	_ = data
	r.Result = "allowed"
	return r
}

// probeWorkspaceWrite attempts to write a file inside /workspace. This should
// succeed under Landlock because /workspace is in the allowed path set.
func probeWorkspaceWrite(path string) ProbeResult {
	r := ProbeResult{
		Probe:  "workspace_write",
		Action: "write " + path,
	}

	err := os.WriteFile(path, []byte("nono-containment-probe: write test passed\n"), 0644)
	if err != nil {
		r.Result = "blocked"
		r.Errno = errnoString(err)
		r.LandlockEnforced = isPermissionError(err)
		return r
	}
	r.Result = "allowed"
	return r
}

// runAllProbes executes all containment probes in sequence and returns
// their results.
func runAllProbes(workspaceReadPath, workspaceWritePath string) []ProbeResult {
	return []ProbeResult{
		probeReadShadow(),
		probeWriteOutside(),
		probeMetadataExfil(),
		probeWorkspaceRead(workspaceReadPath),
		probeWorkspaceWrite(workspaceWritePath),
	}
}
