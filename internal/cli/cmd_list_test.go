package cli

import (
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/davis7dotsh/tx9/internal/box"

	"github.com/davis7dotsh/tx9/internal/version"
)

func TestImageVersionDisplay(t *testing.T) {
	cases := []struct {
		name       string
		boxVersion string
		want       string
	}{
		{name: "empty label", boxVersion: "", want: "?"},
		{name: "matches CLI version", boxVersion: version.Version, want: version.Version},
		{
			name:       "drifted from CLI version",
			boxVersion: "0.1.0-not-the-cli-version",
			want:       "0.1.0-not-the-cli-version (cli: " + version.Version + ")",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := imageVersionDisplay(tc.boxVersion); got != tc.want {
				t.Errorf("imageVersionDisplay(%q) = %q, want %q", tc.boxVersion, got, tc.want)
			}
		})
	}
}

func TestCommandsWithoutPositionalsRejectArgumentsBeforeDocker(t *testing.T) {
	t.Setenv("DOCKER_HOST", "invalid://must-not-connect")
	for _, tc := range []struct {
		name string
		run  commandFunc
	}{{"list", cmdList}, {"prune", cmdPrune}} {
		t.Run(tc.name, func(t *testing.T) {
			if err := tc.run([]string{"fixture"}); err == nil || !strings.Contains(err.Error(), "unexpected positional") {
				t.Fatalf("ignored box name or contacted Docker: %v", err)
			}
		})
	}
}

func TestListURLCollectionBoundsConcurrencyAndPreservesOrder(t *testing.T) {
	boxes := listBenchmarkBoxes()
	var mu sync.Mutex
	active, peak, calls := 0, 0, 0
	firstBatch := make(chan struct{})
	timer := time.AfterFunc(5*time.Second, func() { close(firstBatch) })
	defer timer.Stop()
	urls := collectListURLs(boxes, func(b *box.Box) (string, error) {
		mu.Lock()
		active++
		calls++
		peak = max(peak, active)
		if calls == 4 && timer.Stop() {
			close(firstBatch)
		}
		mu.Unlock()
		<-firstBatch
		mu.Lock()
		active--
		mu.Unlock()
		return "https://" + b.Name + ".example/", nil
	})
	if peak != 4 || calls != len(boxes) {
		t.Fatalf("peak=%d calls=%d, want bounded parallel inspection of %d boxes", peak, calls, len(boxes))
	}
	for i, b := range boxes {
		if urls[i] != "https://"+b.Name+".example/" {
			t.Fatalf("result order changed: %v", urls)
		}
	}
}

func TestListURLCollectionSkipsStoppedAndToleratesMissingContainers(t *testing.T) {
	boxes := []box.Box{
		{Name: "stopped", AgentID: "agent", ExecutorID: "executor"},
		{Name: "missing", AgentID: "agent", AgentState: "running"},
		{Name: "failed", AgentID: "agent", ExecutorID: "executor", AgentState: "running", ExecutorState: "running"},
	}
	calls := 0
	urls := collectListURLs(boxes, func(b *box.Box) (string, error) {
		calls++
		if b.Name != "failed" {
			t.Errorf("inspected stopped/missing container for %s", b.Name)
		}
		return "", fmt.Errorf("container disappeared")
	})
	if calls != 1 || !reflect.DeepEqual(urls, []string{"-", "-", "-"}) {
		t.Fatalf("calls=%d urls=%v", calls, urls)
	}
	if got := collectListURLs(nil, nil); len(got) != 0 {
		t.Fatalf("empty box list: %v", got)
	}
}

func listBenchmarkBoxes() []box.Box {
	boxes := make([]box.Box, 16)
	for i := range boxes {
		boxes[i] = box.Box{Name: fmt.Sprintf("box-%02d", i), AgentID: "agent", ExecutorID: "executor", AgentState: "running", ExecutorState: "running"}
	}
	return boxes
}

func BenchmarkListDashboardLookup(b *testing.B) {
	boxes := listBenchmarkBoxes()
	lookup := func(entry *box.Box) (string, error) {
		// Simulate modest Docker API latency without requiring a daemon.
		time.Sleep(time.Millisecond)
		return entry.Name, nil
	}
	b.Run("serial", func(b *testing.B) {
		for b.Loop() {
			for i := range boxes {
				_, _ = lookup(&boxes[i])
			}
		}
	})
	b.Run("parallel", func(b *testing.B) {
		for b.Loop() {
			collectListURLs(boxes, lookup)
		}
	})
}
