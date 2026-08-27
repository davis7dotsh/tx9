package cli

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/docker/go-connections/nat"
)

func TestHostProbeURLUsesPublishedAddress(t *testing.T) {
	for _, tc := range []struct{ host, want string }{
		{"", "http://127.0.0.1:4790/"},
		{"0.0.0.0", "http://127.0.0.1:4790/"},
		{"192.0.2.7", "http://192.0.2.7:4790/"},
		{"127.0.0.2", "http://127.0.0.2:4790/"},
		{"::", "http://[::1]:4790/"},
	} {
		if got := hostProbeURL(nat.PortBinding{HostIP: tc.host, HostPort: "4790"}); got != tc.want {
			t.Errorf("host %q: got %q, want %q", tc.host, got, tc.want)
		}
	}
}

func TestHostProbeStopsRetryingWhenCanceled(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		cancel()
		http.Error(w, "not ready", http.StatusServiceUnavailable)
	}))
	defer server.Close()
	host, port, err := net.SplitHostPort(server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	if err := probeHostPort(ctx, nat.PortBinding{HostIP: host, HostPort: port}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation not propagated: %v", err)
	}
}

func TestProbeExecutorPublicURL(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/health" {
			t.Errorf("path = %q, want /api/health", r.URL.Path)
		}
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()

	if err := probeExecutorPublicURL(context.Background(), server.URL); err != nil {
		t.Fatal(err)
	}
}

func TestProbeExecutorPublicURLRejectsBadHealth(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "not ready", http.StatusServiceUnavailable)
	}))
	defer server.Close()

	if err := probeExecutorPublicURL(context.Background(), server.URL); err == nil {
		t.Fatal("expected health probe error")
	}
}
