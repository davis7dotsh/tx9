package box

import (
	"os"
	"reflect"
	"slices"
	"syscall"
	"testing"
	"time"

	"github.com/davis7dotsh/tx9/internal/state"
)

func TestNewAgentMountNormalizesAndPrepares(t *testing.T) {
	source := t.TempDir()
	if err := os.Chmod(source, 0o755); err != nil {
		t.Fatal(err)
	}

	mount, err := NewAgentMount(source+"/.", "/mnt/library/..//agents", true, false)
	if err != nil {
		t.Fatal(err)
	}
	if mount.Source != source {
		t.Errorf("Source = %q, want %q", mount.Source, source)
	}
	if mount.Target != "/mnt/agents" {
		t.Errorf("Target = %q, want /mnt/agents", mount.Target)
	}
	binds, groups, err := prepareAgentMounts([]AgentMount{mount})
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{source + ":/mnt/agents:ro"}; !reflect.DeepEqual(binds, want) {
		t.Errorf("binds = %#v, want %#v", binds, want)
	}
	if len(groups) != 0 {
		t.Errorf("groups = %#v, want none for a world-readable directory", groups)
	}
}

func TestAgentMountRejectsDurableDataTargets(t *testing.T) {
	source := t.TempDir()
	if err := os.Chmod(source, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{"/data/home/agent/agents", "/mnt", "relative"} {
		if _, err := NewAgentMount(source, target, false, false); err == nil {
			t.Errorf("NewAgentMount target %q succeeded, want error", target)
		}
	}
}

func TestAgentMountRequireMountpointRejectsPlainDirectory(t *testing.T) {
	source := t.TempDir()
	if err := os.Chmod(source, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := NewAgentMount(source, "/mnt/plain", false, true); err == nil {
		t.Fatal("NewAgentMount accepted a plain directory with RequireMountpoint")
	}
}

func TestAgentMountPersistencePreservesOtherBoxState(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := state.WriteBoxEnv("media-bot", map[string]string{
		"EXECUTOR_MCP_TOKEN": "secret",
		"FUTURE_SETTING":     "preserve-me",
	}); err != nil {
		t.Fatal(err)
	}
	mounts := []AgentMount{{
		Source:            "/home/davis/agents",
		Target:            "/mnt/agents",
		RequireMountpoint: true,
	}}
	if err := SaveAgentMounts("media-bot", mounts); err != nil {
		t.Fatal(err)
	}
	got, err := LoadAgentMounts("media-bot")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, mounts) {
		t.Errorf("LoadAgentMounts = %#v, want %#v", got, mounts)
	}
	env, err := state.ReadBoxEnv("media-bot")
	if err != nil {
		t.Fatal(err)
	}
	if env["EXECUTOR_MCP_TOKEN"] != "secret" || env["FUTURE_SETTING"] != "preserve-me" {
		t.Errorf("other box state was not preserved: %#v", env)
	}
	if err := SaveAgentMounts("media-bot", nil); err != nil {
		t.Fatal(err)
	}
	env, err = state.ReadBoxEnv("media-bot")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := env[AgentMountsEnv]; ok {
		t.Errorf("%s remains after clearing mounts", AgentMountsEnv)
	}
}

func TestValidateAgentMountSetRejectsDuplicateTargets(t *testing.T) {
	err := validateAgentMountSet([]AgentMount{
		{Source: "/host/a", Target: "/mnt/shared"},
		{Source: "/host/b", Target: "/mnt/shared"},
	})
	if err == nil {
		t.Fatal("duplicate target accepted")
	}
}

func TestSupplementalGroup(t *testing.T) {
	cases := []struct {
		name     string
		uid      uint32
		gid      uint32
		mode     os.FileMode
		readOnly bool
		want     string
		wantErr  bool
	}{
		{name: "host group grants rw", uid: 1000, gid: 1000, mode: 0o770, want: "1000"},
		{name: "agent owns source", uid: agentUID, gid: 1000, mode: 0o700},
		{name: "world readable", uid: 1000, gid: 1000, mode: 0o755, readOnly: true},
		{name: "read-only uses rx", uid: 1000, gid: 2000, mode: 0o750, readOnly: true, want: "2000"},
		{name: "root group is not injected", uid: 0, gid: 0, mode: 0o770, wantErr: true},
		// Owner class governs exclusively: mode 0577's other bits cannot
		// compensate for the owner's missing write bit.
		{name: "agent-owned dir with restrictive owner bits", uid: agentUID, gid: 1000, mode: 0o577, wantErr: true},
		{name: "agent primary group grants ro", uid: 1000, gid: agentGID, mode: 0o750, readOnly: true},
		// Group class governs exclusively for the agent's primary group:
		// other bits cannot compensate.
		{name: "agent primary group denies despite other bits", uid: 1000, gid: agentGID, mode: 0o705, readOnly: true, wantErr: true},
		{name: "other bits suffice without joining the group", uid: 1000, gid: 2000, mode: 0o707},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			info := fakeMountFileInfo{
				mode: tc.mode | os.ModeDir,
				stat: &syscall.Stat_t{Uid: tc.uid, Gid: tc.gid},
			}
			got, err := supplementalGroup(info, tc.readOnly)
			if (err != nil) != tc.wantErr {
				t.Fatalf("error = %v, wantErr %v", err, tc.wantErr)
			}
			if got != tc.want {
				t.Errorf("group = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestUnescapeMountInfoPath(t *testing.T) {
	got := unescapeMountInfoPath(`/home/davis/thumbnail\040inspo\134raw`)
	if got != "/home/davis/thumbnail inspo\\raw" {
		t.Errorf("unescapeMountInfoPath = %q", got)
	}
}

func TestAgentContainerSpecPropagatesMountGroups(t *testing.T) {
	spec := newAgentContainerSpec(
		"media-bot", "tx9-box:test", "token", "test", "network", "agent-volume",
		[]string{"/host/agents:/mnt/agents"}, []string{"1000", "2000"},
	)
	if !slices.Contains(spec.Env, "TX9_AGENT_MOUNT_GIDS=1000,2000") {
		t.Errorf("Env = %#v, want TX9_AGENT_MOUNT_GIDS", spec.Env)
	}
	if !reflect.DeepEqual(spec.GroupAdd, []string{"1000", "2000"}) {
		t.Errorf("GroupAdd = %#v", spec.GroupAdd)
	}
}

type fakeMountFileInfo struct {
	mode os.FileMode
	stat *syscall.Stat_t
}

func (f fakeMountFileInfo) Name() string       { return "mount" }
func (f fakeMountFileInfo) Size() int64        { return 0 }
func (f fakeMountFileInfo) Mode() os.FileMode  { return f.mode }
func (f fakeMountFileInfo) ModTime() time.Time { return time.Time{} }
func (f fakeMountFileInfo) IsDir() bool        { return true }
func (f fakeMountFileInfo) Sys() any           { return f.stat }
