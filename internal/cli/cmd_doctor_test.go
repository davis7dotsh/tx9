package cli

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

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
