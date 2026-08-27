package cli

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/go-connections/nat"

	"github.com/davis7dotsh/tx9/internal/box"
)

type overviewTestClient struct {
	inspect func(context.Context, string) (container.InspectResponse, error)
	usage   func(context.Context, ...string) (map[string]int64, []string, error)
}

func (c overviewTestClient) ContainerInspect(ctx context.Context, id string) (container.InspectResponse, error) {
	return c.inspect(ctx, id)
}

func (c overviewTestClient) VolumeUsage(ctx context.Context, names ...string) (map[string]int64, []string, error) {
	return c.usage(ctx, names...)
}

func overviewFixture() container.InspectResponse {
	return container.InspectResponse{
		ContainerJSONBase: &container.ContainerJSONBase{
			HostConfig: &container.HostConfig{Resources: container.Resources{NanoCPUs: 2_000_000_000, Memory: 2 << 30}},
		},
		NetworkSettings: &container.NetworkSettings{
			NetworkSettingsBase: container.NetworkSettingsBase{Ports: nat.PortMap{"4788/tcp": {{HostPort: "4790"}}}},
		},
	}
}

func TestOverviewInspectsWhileVolumeUsageWaits(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("TX9_URL_HOST", "example.test")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var mu sync.Mutex
	calls := map[string]int{}
	inspected := make(chan struct{})
	client := overviewTestClient{
		inspect: func(_ context.Context, id string) (container.InspectResponse, error) {
			mu.Lock()
			defer mu.Unlock()
			calls[id]++
			if id == "executor" && calls[id] == 1 {
				close(inspected)
			}
			return overviewFixture(), nil
		},
		usage: func(ctx context.Context, names ...string) (map[string]int64, []string, error) {
			select {
			case <-inspected:
				return map[string]int64{names[0]: 42}, nil, nil
			case <-ctx.Done():
				return nil, nil, ctx.Err()
			}
		},
	}
	entries, warnings := collectOverview(ctx, client, []box.Box{{Name: "box", AgentID: "agent", ExecutorID: "executor", AgentState: "running", ExecutorState: "running"}})
	if len(warnings) != 0 {
		t.Fatalf("warnings: %v", warnings)
	}
	if calls["agent"] != 1 || calls["executor"] != 1 {
		t.Fatalf("inspect calls: %v", calls)
	}
	entry := entries[0]
	if !entry.Agent.Inspected || !entry.Executor.Inspected || entry.DashboardURL != "http://example.test:4790/" {
		t.Fatalf("metadata missing: %+v", entry)
	}
	if entry.AgentVolume.UsedBytes != 42 || entry.ExecutorVolume.UsedBytes != -1 {
		t.Fatalf("volume usage: %+v / %+v", entry.AgentVolume, entry.ExecutorVolume)
	}
}

func TestOverviewBoundsInspectionConcurrency(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var mu sync.Mutex
	active, peak, calls := 0, 0, 0
	firstBatch := make(chan struct{})
	client := overviewTestClient{
		inspect: func(ctx context.Context, _ string) (container.InspectResponse, error) {
			mu.Lock()
			active++
			calls++
			peak = max(peak, active)
			if calls == 4 {
				close(firstBatch)
			}
			mu.Unlock()
			select {
			case <-firstBatch:
			case <-ctx.Done():
			}
			mu.Lock()
			active--
			mu.Unlock()
			return overviewFixture(), nil
		},
		usage: func(context.Context, ...string) (map[string]int64, []string, error) { return nil, nil, nil },
	}
	boxes := make([]box.Box, 12)
	for i := range boxes {
		boxes[i] = box.Box{Name: fmt.Sprintf("box-%d", i), AgentID: "agent", ExecutorID: "executor"}
	}
	entries, warnings := collectOverview(ctx, client, boxes)
	if ctx.Err() != nil || peak != 4 || calls != len(boxes)*2 || len(warnings) != 0 {
		t.Fatalf("peak=%d calls=%d warnings=%v context=%v", peak, calls, warnings, ctx.Err())
	}
	for i, entry := range entries {
		if entry.Name != boxes[i].Name {
			t.Fatalf("result order changed: %v", entries)
		}
	}
}

func TestOverviewReportsPartialFailuresWithoutInventingUsage(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	client := overviewTestClient{
		inspect: func(context.Context, string) (container.InspectResponse, error) {
			return container.InspectResponse{}, fmt.Errorf("inspection failed")
		},
		usage: func(context.Context, ...string) (map[string]int64, []string, error) {
			return nil, nil, context.DeadlineExceeded
		},
	}
	entries, warnings := collectOverview(context.Background(), client, []box.Box{{Name: "box", AgentID: "agent"}})
	if entries[0].Agent.Inspected || !entries[0].Executor.Missing || entries[0].AgentVolume.UsedBytes != -1 {
		t.Fatalf("invented metadata: %+v", entries[0])
	}
	if len(warnings) != 2 || !strings.Contains(warnings[0], "agent") || !strings.Contains(warnings[1], "volume usage") {
		t.Fatalf("warnings: %v", warnings)
	}
}

func TestOverviewEmptyDoesNotQueryDocker(t *testing.T) {
	entries, warnings := collectOverview(context.Background(), overviewTestClient{}, nil)
	if len(entries) != 0 || len(warnings) != 0 {
		t.Fatalf("unexpected result: %v %v", entries, warnings)
	}
}
