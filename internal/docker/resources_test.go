package docker

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/docker/docker/api/types/container"
	dockerclient "github.com/docker/docker/client"
)

func TestDefaultMemorySwapLimit(t *testing.T) {
	got, err := defaultMemorySwapLimit(8 << 30)
	if err != nil {
		t.Fatal(err)
	}
	if got != 16<<30 {
		t.Fatalf("defaultMemorySwapLimit(8GiB) = %d, want %d", got, int64(16<<30))
	}
	if got, err := defaultMemorySwapLimit(0); err != nil || got != 0 {
		t.Fatalf("defaultMemorySwapLimit(0) = %d, %v, want 0, nil", got, err)
	}
	if _, err := defaultMemorySwapLimit(math.MaxInt64/2 + 1); err == nil {
		t.Fatal("defaultMemorySwapLimit(overflow) error = nil")
	}
}

func TestVolumeUsageMapsDaemonResponseAndMissingVolumes(t *testing.T) {
	cli := newTestDockerClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || !strings.HasSuffix(r.URL.Path, "/system/df") {
			t.Fatalf("request = %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"Volumes":[{"Name":"agent-data","Driver":"local","UsageData":{"Size":1234,"RefCount":1}}]}`))
	})

	usage, warnings, err := cli.VolumeUsage(context.Background(), "agent-data", "exec-data")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(usage, map[string]int64{"agent-data": 1234, "exec-data": -1}) {
		t.Fatalf("usage = %#v", usage)
	}
	if len(warnings) != 1 || !strings.Contains(warnings[0], "exec-data") {
		t.Fatalf("warnings = %#v", warnings)
	}
}

func TestContainerUpdateResourcesSendsMemorySwapAtomically(t *testing.T) {
	cli := newTestDockerClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || !strings.HasSuffix(r.URL.Path, "/containers/container-id/update") {
			t.Fatalf("request = %s %s", r.Method, r.URL.Path)
		}
		var update container.UpdateConfig
		if err := json.NewDecoder(r.Body).Decode(&update); err != nil {
			t.Fatal(err)
		}
		if update.NanoCPUs != 3_000_000_000 || update.Memory != 4<<30 || update.MemorySwap != 8<<30 {
			t.Fatalf("update resources = nano=%d memory=%d swap=%d", update.NanoCPUs, update.Memory, update.MemorySwap)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"Warnings":["daemon warning"]}`))
	})

	warnings, err := cli.ContainerUpdateResources(context.Background(), "container-id", 3_000_000_000, 4<<30)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(warnings, []string{"daemon warning"}) {
		t.Fatalf("warnings = %#v", warnings)
	}
}

func newTestDockerClient(t *testing.T, handler http.HandlerFunc) *Client {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	sdk, err := dockerclient.NewClientWithOpts(
		dockerclient.WithHost(server.URL),
		dockerclient.WithVersion("1.47"),
		dockerclient.WithHTTPClient(server.Client()),
	)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sdk.Close() })
	return &Client{cli: sdk}
}
