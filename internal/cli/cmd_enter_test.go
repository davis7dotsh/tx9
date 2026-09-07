package cli

import (
	"slices"
	"strings"
	"testing"
)

func TestEnterExecKeepsBearerTokensOutOfArguments(t *testing.T) {
	for _, intoExecutor := range []bool{false, true} {
		tokenKey := "BOXD_EXECUTOR_TOKEN"
		if intoExecutor {
			tokenKey = "EXECUTOR_MCP_TOKEN"
		}
		t.Run(tokenKey, func(t *testing.T) {
			const token = "synthetic-current-box-token"
			inherited := []string{
				"PATH=/usr/bin", "DOCKER_HOST=unix:///fixture.sock",
				"BOXD_EXECUTOR_TOKEN=stale-agent-token", "EXECUTOR_MCP_TOKEN=stale-executor-token",
			}
			before := slices.Clone(inherited)
			argv, env := enterExecCommand("/usr/bin/docker", "fixture-id", token, intoExecutor, inherited)
			for _, arg := range argv {
				if strings.Contains(arg, token) || strings.Contains(arg, "stale-") {
					t.Fatal("Docker argument contains a bearer token")
				}
			}
			foundLookup := false
			for i := 1; i < len(argv); i++ {
				if argv[i-1] == "-e" && argv[i] == tokenKey {
					foundLookup = true
				}
			}
			if !foundLookup {
				t.Fatalf("Docker arguments do not look up %s from the environment", tokenKey)
			}
			wantEnv := []string{"PATH=/usr/bin", "DOCKER_HOST=unix:///fixture.sock", tokenKey + "=" + token}
			if !slices.Equal(env, wantEnv) {
				t.Fatal("Docker environment does not contain exactly the current box token and unrelated inherited values")
			}
			if !slices.Equal(inherited, before) {
				t.Fatal("inherited environment was modified")
			}
		})
	}
}
