package box

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"

	"github.com/davis7dotsh/tx9/internal/state"
)

const (
	// AgentMountsEnv is the per-box state key used for host bind mounts.
	// The value is JSON rather than a delimiter-separated list so paths with
	// spaces round-trip without shell-style parsing.
	AgentMountsEnv = "TX9_AGENT_MOUNTS"
	agentUID       = 1001
)

// AgentMount describes one host directory exposed to the agent container.
// Targets are deliberately restricted to /mnt so external data stays outside
// /data, the durable volume captured by tx9 backup.
type AgentMount struct {
	Source            string `json:"source"`
	Target            string `json:"target"`
	ReadOnly          bool   `json:"read_only,omitempty"`
	RequireMountpoint bool   `json:"require_mountpoint,omitempty"`
}

// NewAgentMount normalizes and validates an operator-provided mount.
func NewAgentMount(source, target string, readOnly, requireMountpoint bool) (AgentMount, error) {
	absSource, err := filepath.Abs(source)
	if err != nil {
		return AgentMount{}, fmt.Errorf("agent mount source %q: %w", source, err)
	}
	if resolved, err := filepath.EvalSymlinks(absSource); err == nil {
		absSource = resolved
	}
	mount := AgentMount{
		Source:            filepath.Clean(absSource),
		Target:            path.Clean(target),
		ReadOnly:          readOnly,
		RequireMountpoint: requireMountpoint,
	}
	if err := validateAgentMount(mount); err != nil {
		return AgentMount{}, err
	}
	if _, err := prepareAgentMount(mount); err != nil {
		return AgentMount{}, err
	}
	return mount, nil
}

// LoadAgentMounts reads and validates the persisted desired mount set. It does
// not require sources to be online; list/remove must still work while a NAS is
// unavailable. Create and recreation perform the live checks.
func LoadAgentMounts(name string) ([]AgentMount, error) {
	env, err := state.ReadBoxEnv(name)
	if err != nil {
		return nil, fmt.Errorf("box: load agent mounts %s: %w", name, err)
	}
	raw := env[AgentMountsEnv]
	if raw == "" {
		return nil, nil
	}
	var mounts []AgentMount
	if err := json.Unmarshal([]byte(raw), &mounts); err != nil {
		return nil, fmt.Errorf("box: load agent mounts %s: invalid %s JSON: %w", name, AgentMountsEnv, err)
	}
	if err := validateAgentMountSet(mounts); err != nil {
		return nil, fmt.Errorf("box: load agent mounts %s: %w", name, err)
	}
	return mounts, nil
}

// SaveAgentMounts updates the persisted desired mount set without discarding
// the Executor token or settings owned by newer tx9 versions.
func SaveAgentMounts(name string, mounts []AgentMount) error {
	if err := validateAgentMountSet(mounts); err != nil {
		return fmt.Errorf("box: save agent mounts %s: %w", name, err)
	}
	env, err := state.ReadBoxEnv(name)
	if err != nil {
		return fmt.Errorf("box: save agent mounts %s: %w", name, err)
	}
	if len(mounts) == 0 {
		delete(env, AgentMountsEnv)
	} else {
		encoded, err := json.Marshal(mounts)
		if err != nil {
			return fmt.Errorf("box: save agent mounts %s: %w", name, err)
		}
		env[AgentMountsEnv] = string(encoded)
	}
	if err := state.WriteBoxEnv(name, env); err != nil {
		return fmt.Errorf("box: save agent mounts %s: %w", name, err)
	}
	return nil
}

// PreflightAgentMounts verifies that every desired source is online and
// accessible before a caller begins destructive container recreation.
func PreflightAgentMounts(mounts []AgentMount) error {
	_, _, err := prepareAgentMounts(mounts)
	return err
}

func validateAgentMountSet(mounts []AgentMount) error {
	targets := map[string]bool{}
	for _, mount := range mounts {
		if err := validateAgentMount(mount); err != nil {
			return err
		}
		if targets[mount.Target] {
			return fmt.Errorf("agent mount target %q is configured more than once", mount.Target)
		}
		targets[mount.Target] = true
	}
	return nil
}

func validateAgentMount(mount AgentMount) error {
	if mount.Source == "" || !filepath.IsAbs(mount.Source) || filepath.Clean(mount.Source) != mount.Source {
		return fmt.Errorf("agent mount source must be a clean absolute host path: %q", mount.Source)
	}
	if strings.ContainsAny(mount.Source, ":\n\r\x00") {
		return fmt.Errorf("agent mount source contains a character Docker bind syntax cannot represent: %q", mount.Source)
	}
	if mount.Target == "" || !path.IsAbs(mount.Target) || path.Clean(mount.Target) != mount.Target {
		return fmt.Errorf("agent mount target must be a clean absolute container path: %q", mount.Target)
	}
	if mount.Target == "/mnt" || !strings.HasPrefix(mount.Target, "/mnt/") {
		return fmt.Errorf("agent mount target must be below /mnt so tx9 backups cannot traverse external data: %q", mount.Target)
	}
	if strings.ContainsAny(mount.Target, ":\n\r\x00") {
		return fmt.Errorf("agent mount target contains a character Docker bind syntax cannot represent: %q", mount.Target)
	}
	return nil
}

type preparedAgentMount struct {
	bind  string
	group string
}

func prepareAgentMounts(mounts []AgentMount) ([]string, []string, error) {
	if err := validateAgentMountSet(mounts); err != nil {
		return nil, nil, err
	}
	binds := make([]string, 0, len(mounts))
	groupSet := map[string]bool{}
	for _, mount := range mounts {
		prepared, err := prepareAgentMount(mount)
		if err != nil {
			return nil, nil, err
		}
		binds = append(binds, prepared.bind)
		if prepared.group != "" {
			groupSet[prepared.group] = true
		}
	}
	groups := make([]string, 0, len(groupSet))
	for group := range groupSet {
		groups = append(groups, group)
	}
	sort.Strings(groups)
	return binds, groups, nil
}

func prepareAgentMount(mount AgentMount) (preparedAgentMount, error) {
	info, err := os.Stat(mount.Source)
	if err != nil {
		return preparedAgentMount{}, fmt.Errorf("agent mount source %q is unavailable: %w", mount.Source, err)
	}
	if !info.IsDir() {
		return preparedAgentMount{}, fmt.Errorf("agent mount source must be a directory: %q", mount.Source)
	}
	if mount.RequireMountpoint {
		mounted, err := isMountpoint(mount.Source)
		if err != nil {
			return preparedAgentMount{}, fmt.Errorf("verify required mountpoint %q: %w", mount.Source, err)
		}
		if !mounted {
			return preparedAgentMount{}, fmt.Errorf("agent mount source %q is not currently a mountpoint; refusing to bind its underlying directory", mount.Source)
		}
	}

	bind := mount.Source + ":" + mount.Target
	if mount.ReadOnly {
		bind += ":ro"
	}
	group, err := supplementalGroup(info, mount.ReadOnly)
	if err != nil {
		return preparedAgentMount{}, fmt.Errorf("agent mount source %q: %w", mount.Source, err)
	}
	return preparedAgentMount{bind: bind, group: group}, nil
}

func supplementalGroup(info os.FileInfo, readOnly bool) (string, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "", nil
	}
	needed := uint32(0o5)
	if !readOnly {
		needed = 0o7
	}
	permissions := uint32(info.Mode().Perm())
	if stat.Uid == agentUID && (permissions>>6)&needed == needed {
		return "", nil
	}
	if permissions&needed == needed {
		return "", nil
	}
	if stat.Gid != 0 && (permissions>>3)&needed == needed {
		return strconv.FormatUint(uint64(stat.Gid), 10), nil
	}
	mode := "read"
	if !readOnly {
		mode = "read/write"
	}
	return "", fmt.Errorf("directory mode %04o does not give agent UID %d %s access through owner, group, or other bits", info.Mode().Perm(), agentUID, mode)
}

func isMountpoint(target string) (bool, error) {
	f, err := os.Open("/proc/self/mountinfo")
	if err != nil {
		return false, fmt.Errorf("read /proc/self/mountinfo: %w", err)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) > 4 && unescapeMountInfoPath(fields[4]) == target {
			return true, nil
		}
	}
	if err := scanner.Err(); err != nil {
		return false, err
	}
	return false, nil
}

func unescapeMountInfoPath(value string) string {
	return strings.NewReplacer(
		`\040`, " ",
		`\011`, "\t",
		`\012`, "\n",
		`\134`, `\`,
	).Replace(value)
}
