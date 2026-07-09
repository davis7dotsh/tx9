package box

import (
	"net"
	"testing"
)

func TestContainerNames(t *testing.T) {
	agent, executor := ContainerNames("dry1")
	if agent != "tx9-dry1-agent" {
		t.Errorf("agent name = %q, want tx9-dry1-agent", agent)
	}
	if executor != "tx9-dry1-executor" {
		t.Errorf("executor name = %q, want tx9-dry1-executor", executor)
	}
}

func TestNetworkName(t *testing.T) {
	if got := NetworkName("dry1"); got != "tx9-dry1" {
		t.Errorf("NetworkName = %q, want tx9-dry1", got)
	}
}

func TestVolumeNames(t *testing.T) {
	agentVol, execVol := VolumeNames("dry1")
	if agentVol != "tx9-dry1-agent-data" {
		t.Errorf("agent volume = %q, want tx9-dry1-agent-data", agentVol)
	}
	if execVol != "tx9-dry1-exec-data" {
		t.Errorf("executor volume = %q, want tx9-dry1-exec-data", execVol)
	}
}

func TestDerivedState(t *testing.T) {
	cases := []struct {
		name string
		b    Box
		want string
	}{
		{
			name: "both running",
			b:    Box{AgentID: "a", ExecutorID: "e", AgentState: "running", ExecutorState: "running"},
			want: "running",
		},
		{
			name: "both stopped",
			b:    Box{AgentID: "a", ExecutorID: "e", AgentState: "exited", ExecutorState: "exited"},
			want: "stopped",
		},
		{
			name: "mixed: agent up, executor down",
			b:    Box{AgentID: "a", ExecutorID: "e", AgentState: "running", ExecutorState: "exited"},
			want: "mixed",
		},
		{
			name: "mixed: executor up, agent down",
			b:    Box{AgentID: "a", ExecutorID: "e", AgentState: "exited", ExecutorState: "running"},
			want: "mixed",
		},
		{
			name: "crashed: agent container missing entirely",
			b:    Box{AgentID: "", ExecutorID: "e", AgentState: "", ExecutorState: "running"},
			want: "crashed",
		},
		{
			name: "crashed: executor container missing entirely",
			b:    Box{AgentID: "a", ExecutorID: "", AgentState: "running", ExecutorState: ""},
			want: "crashed",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.b.DerivedState(); got != tc.want {
				t.Errorf("DerivedState() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestURLHostEnvOverride(t *testing.T) {
	t.Setenv("TX9_URL_HOST", "box.example.com")
	if got := URLHost(); got != "box.example.com" {
		t.Errorf("URLHost() = %q, want box.example.com", got)
	}
}

func TestURLHostFallsBackToHostname(t *testing.T) {
	t.Setenv("TX9_URL_HOST", "")
	got := URLHost()
	if got == "" {
		t.Error("URLHost() = \"\", want a non-empty IP, hostname, or \"localhost\" fallback")
	}
}

func TestURLHostPrefersTailscaleIP(t *testing.T) {
	t.Setenv("TX9_URL_HOST", "")
	ts := tailscaleIP()
	if ts == "" {
		t.Skip("no Tailscale interface on this machine")
	}
	if got := URLHost(); got != ts {
		t.Errorf("URLHost() = %q, want the Tailscale IP %q", got, ts)
	}
}

func TestTailscaleIPRange(t *testing.T) {
	if ip := tailscaleIP(); ip != "" && !tailscaleCGNAT.Contains(net.ParseIP(ip)) {
		t.Errorf("tailscaleIP() = %q, want an address in 100.64.0.0/10", ip)
	}
}

func TestDashboardURL(t *testing.T) {
	t.Setenv("TX9_URL_HOST", "box.example.com")
	if got := DashboardURL("32768", ""); got != "http://box.example.com:32768/" {
		t.Errorf("DashboardURL() = %q, want http://box.example.com:32768/", got)
	}
	if got := DashboardURL("32768", "https://box.example.ts.net"); got != "https://box.example.ts.net/" {
		t.Errorf("DashboardURL() = %q, want public HTTPS URL", got)
	}
}

func TestOpenURL(t *testing.T) {
	t.Setenv("TX9_URL_HOST", "box.example.com")
	got, err := OpenURL("32768", "sekret", "")
	if err != nil {
		t.Fatal(err)
	}
	want := "http://box.example.com:32768/?_token=sekret"
	if got != want {
		t.Errorf("OpenURL() = %q, want %q", got, want)
	}
	got, err = OpenURL("32768", "secret with spaces", "https://box.example.ts.net")
	if err != nil {
		t.Fatal(err)
	}
	want = "https://box.example.ts.net/?_token=secret+with+spaces"
	if got != want {
		t.Errorf("OpenURL() = %q, want %q", got, want)
	}
}
