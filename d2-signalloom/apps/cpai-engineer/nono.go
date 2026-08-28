package main

import (
	"fmt"
	"os/exec"
	"strings"
)

// NonoWrapper builds nono sandbox commands for Landlock-confined execution.
//
// nono is a Landlock LSM tool that restricts filesystem and network access.
// All code execution inside cpai-engineer runs through this wrapper so the
// agent can only touch /workspace and /tmp, regardless of what the LLM
// attempts.
type NonoWrapper struct {
	Profile string
}

// NewNonoWrapper creates a wrapper for the named nono profile.
func NewNonoWrapper(profile string) *NonoWrapper {
	return &NonoWrapper{Profile: profile}
}

// profilePaths returns the filesystem access rules for the given profile.
func (n *NonoWrapper) profilePaths() (allowRead, allowWrite []string) {
	switch n.Profile {
	case "strict":
		return []string{"/workspace", "/tmp", "/usr/lib", "/lib"},
			[]string{"/workspace", "/tmp"}
	case "relaxed":
		return []string{"/workspace", "/tmp", "/usr/lib", "/lib", "/usr/local"},
			[]string{"/workspace", "/tmp", "/usr/local/tmp"}
	default:
		// Fall back to strict.
		return []string{"/workspace", "/tmp", "/usr/lib", "/lib"},
			[]string{"/workspace", "/tmp"}
	}
}

// Wrap returns an exec.Cmd that runs the given command inside the nono sandbox.
func (n *NonoWrapper) Wrap(name string, args ...string) *exec.Cmd {
	nonoArgs := n.buildArgs(name, args...)
	return exec.Command("nono", nonoArgs...)
}

// WrapWithDir returns an exec.Cmd with the working directory set.
func (n *NonoWrapper) WrapWithDir(dir, name string, args ...string) *exec.Cmd {
	cmd := n.Wrap(name, args...)
	cmd.Dir = dir
	return cmd
}

// buildArgs constructs the nono CLI arguments.
func (n *NonoWrapper) buildArgs(name string, args ...string) []string {
	readPaths, writePaths := n.profilePaths()

	var nonoArgs []string
	for _, p := range readPaths {
		nonoArgs = append(nonoArgs, "--allow-read", p)
	}
	for _, p := range writePaths {
		nonoArgs = append(nonoArgs, "--allow-write", p)
	}
	nonoArgs = append(nonoArgs, "--")
	nonoArgs = append(nonoArgs, name)
	nonoArgs = append(nonoArgs, args...)
	return nonoArgs
}

// CommandString returns the full nono command as a string for logging.
func (n *NonoWrapper) CommandString(name string, args ...string) string {
	full := n.buildArgs(name, args...)
	return fmt.Sprintf("nono %s", strings.Join(full, " "))
}
