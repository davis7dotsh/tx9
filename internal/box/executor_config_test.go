package box

import (
	"reflect"
	"testing"

	"github.com/davis7dotsh/tx9/internal/state"
)

func TestParseExecutorConfig(t *testing.T) {
	cfg, err := parseExecutorConfig(
		"https://nexus.example.ts.net/",
		"127.0.0.1:32770",
		"100.100.100.100, 192.168.40.1,100.100.100.100",
	)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.WebBaseURL != "https://nexus.example.ts.net" {
		t.Errorf("WebBaseURL = %q", cfg.WebBaseURL)
	}
	if cfg.PublishAddress() != "127.0.0.1:32770" {
		t.Errorf("PublishAddress() = %q", cfg.PublishAddress())
	}
	wantDNS := []string{"100.100.100.100", "192.168.40.1"}
	if !reflect.DeepEqual(cfg.DNS, wantDNS) {
		t.Errorf("DNS = %#v, want %#v", cfg.DNS, wantDNS)
	}
}

func TestParseExecutorConfigRejectsInvalidValues(t *testing.T) {
	cases := []struct {
		name    string
		webURL  string
		publish string
		dns     string
	}{
		{name: "relative URL", webURL: "nexus.example.ts.net"},
		{name: "URL path", webURL: "https://nexus.example.ts.net/executor"},
		{name: "URL port", webURL: "https://nexus.example.ts.net:70000"},
		{name: "publish hostname", publish: "localhost:32770"},
		{name: "publish port", publish: "127.0.0.1:70000"},
		{name: "DNS hostname", dns: "magicdns"},
		{name: "IPv6 DNS with disabled container IPv6", dns: "fd7a:115c:a1e0::53"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := parseExecutorConfig(tc.webURL, tc.publish, tc.dns); err == nil {
				t.Fatal("expected an error")
			}
		})
	}
}

func TestExecutorConfigPersistsAndEnvironmentOverrides(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	name := "media-bot"
	stored := ExecutorConfig{
		WebBaseURL:  "https://old.example.ts.net",
		PublishIP:   "127.0.0.1",
		PublishPort: "32770",
		DNS:         []string{"100.100.100.100", "192.168.40.1"},
	}
	if err := SaveExecutorConfig(name, "secret-token", stored); err != nil {
		t.Fatal(err)
	}

	t.Setenv(ExecutorWebBaseURLEnv, "https://new.example.ts.net")
	cfg, err := LoadExecutorConfig(name, ExecutorConfigOverrides{})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.WebBaseURL != "https://new.example.ts.net" {
		t.Errorf("WebBaseURL = %q", cfg.WebBaseURL)
	}
	if cfg.PublishAddress() != stored.PublishAddress() {
		t.Errorf("PublishAddress() = %q", cfg.PublishAddress())
	}

	env, err := state.ReadBoxEnv(name)
	if err != nil {
		t.Fatal(err)
	}
	if env["EXECUTOR_MCP_TOKEN"] != "secret-token" {
		t.Error("executor token was not preserved")
	}
	if env[ExecutorPublishEnv] != "127.0.0.1:32770" {
		t.Errorf("stored publish address = %q", env[ExecutorPublishEnv])
	}
	if env[ExecutorDNSEnv] != "100.100.100.100,192.168.40.1" {
		t.Errorf("stored DNS = %q", env[ExecutorDNSEnv])
	}

	cfg, err = LoadExecutorConfig(name, ExecutorConfigOverrides{
		WebBaseURL: "https://cli.example.ts.net",
	})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.WebBaseURL != "https://cli.example.ts.net" {
		t.Errorf("CLI WebBaseURL = %q", cfg.WebBaseURL)
	}

	cfg, err = LoadExecutorConfig(name, ExecutorConfigOverrides{Clear: true})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.WebBaseURL != "" || cfg.PublishAddress() != "" || len(cfg.DNS) != 0 {
		t.Errorf("cleared config = %#v", cfg)
	}
}
