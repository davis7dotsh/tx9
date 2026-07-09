package box

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"

	"github.com/davis7dotsh/tx9/internal/state"
)

const (
	// Environment variables accepted by create/import/upgrade. Resolved values
	// are persisted in the box env file so later upgrades recreate the same
	// reverse-proxy origin, host binding, and DNS behavior without needing the
	// flags or environment again.
	ExecutorWebBaseURLEnv = "TX9_EXECUTOR_WEB_BASE_URL"
	ExecutorPublishEnv    = "TX9_EXECUTOR_PUBLISH"
	ExecutorDNSEnv        = "TX9_EXECUTOR_DNS"
)

// ExecutorConfig controls the host-facing part of an Executor container.
// Empty values preserve tx9's defaults: a Docker-assigned port bound on all
// IPv4 interfaces, Docker's resolver, and Executor's localhost web base URL.
type ExecutorConfig struct {
	WebBaseURL  string
	PublishIP   string
	PublishPort string
	DNS         []string
}

// ExecutorConfigOverrides are raw CLI values. Non-empty values override the
// corresponding process environment variable and persisted box setting.
type ExecutorConfigOverrides struct {
	WebBaseURL string
	Publish    string
	DNS        string
	Clear      bool
}

// LoadExecutorConfig resolves per-box configuration with this precedence:
// explicit CLI value, TX9_EXECUTOR_* environment, persisted box env.
func LoadExecutorConfig(name string, overrides ExecutorConfigOverrides) (ExecutorConfig, error) {
	if overrides.Clear {
		return parseExecutorConfig("", "", "")
	}
	stored, err := state.ReadBoxEnv(name)
	if err != nil {
		return ExecutorConfig{}, fmt.Errorf("box: executor config %s: %w", name, err)
	}

	webBaseURL := firstConfigured(
		overrides.WebBaseURL,
		os.Getenv(ExecutorWebBaseURLEnv),
		stored[ExecutorWebBaseURLEnv],
	)
	publish := firstConfigured(
		overrides.Publish,
		os.Getenv(ExecutorPublishEnv),
		stored[ExecutorPublishEnv],
	)
	dns := firstConfigured(
		overrides.DNS,
		os.Getenv(ExecutorDNSEnv),
		stored[ExecutorDNSEnv],
	)

	return parseExecutorConfig(webBaseURL, publish, dns)
}

// SaveExecutorConfig writes the token and resolved runtime settings without
// discarding unknown keys that a newer tx9 may have added to the box env file.
func SaveExecutorConfig(name, token string, cfg ExecutorConfig) error {
	env, err := state.ReadBoxEnv(name)
	if err != nil {
		return fmt.Errorf("box: save executor config %s: %w", name, err)
	}
	env["EXECUTOR_MCP_TOKEN"] = token
	setOrDelete(env, ExecutorWebBaseURLEnv, cfg.WebBaseURL)
	setOrDelete(env, ExecutorPublishEnv, cfg.PublishAddress())
	setOrDelete(env, ExecutorDNSEnv, strings.Join(cfg.DNS, ","))
	if err := state.WriteBoxEnv(name, env); err != nil {
		return fmt.Errorf("box: save executor config %s: %w", name, err)
	}
	return nil
}

// PublishAddress returns the normalized Docker host binding, or an empty
// string when Docker should assign a port on all IPv4 interfaces.
func (c ExecutorConfig) PublishAddress() string {
	if c.PublishPort == "" {
		return ""
	}
	return net.JoinHostPort(c.PublishIP, c.PublishPort)
}

func parseExecutorConfig(webBaseURL, publish, dns string) (ExecutorConfig, error) {
	baseURL, err := normalizeWebBaseURL(webBaseURL)
	if err != nil {
		return ExecutorConfig{}, err
	}
	publishIP, publishPort, err := parsePublishAddress(publish)
	if err != nil {
		return ExecutorConfig{}, err
	}
	resolvers, err := parseDNS(dns)
	if err != nil {
		return ExecutorConfig{}, err
	}
	return ExecutorConfig{
		WebBaseURL:  baseURL,
		PublishIP:   publishIP,
		PublishPort: publishPort,
		DNS:         resolvers,
	}, nil
}

func normalizeWebBaseURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return "", fmt.Errorf("executor web base URL must be an absolute http(s) origin: %q", raw)
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return "", fmt.Errorf("executor web base URL must contain only scheme, host, and optional port: %q", raw)
	}
	if port := u.Port(); port != "" {
		portNumber, err := strconv.Atoi(port)
		if err != nil || portNumber < 1 || portNumber > 65535 {
			return "", fmt.Errorf("executor web base URL port must be between 1 and 65535: %q", port)
		}
	}
	u.Path = ""
	return strings.TrimSuffix(u.String(), "/"), nil
}

func parsePublishAddress(raw string) (string, string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "0.0.0.0", "", nil
	}
	host, port, err := net.SplitHostPort(raw)
	if err != nil {
		return "", "", fmt.Errorf("executor publish address must be IP:port (for example 127.0.0.1:32770): %q", raw)
	}
	if host == "" {
		host = "0.0.0.0"
	}
	ip := net.ParseIP(host)
	if ip == nil || ip.To4() == nil {
		return "", "", fmt.Errorf("executor publish address must use an IPv4 address: %q", raw)
	}
	portNumber, err := strconv.Atoi(port)
	if err != nil || portNumber < 1 || portNumber > 65535 {
		return "", "", fmt.Errorf("executor publish port must be between 1 and 65535: %q", port)
	}
	return ip.String(), strconv.Itoa(portNumber), nil
}

func parseDNS(raw string) ([]string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	seen := map[string]bool{}
	var resolvers []string
	for _, value := range strings.Split(raw, ",") {
		value = strings.TrimSpace(value)
		ip := net.ParseIP(value)
		if ip == nil || ip.To4() == nil {
			return nil, fmt.Errorf("executor DNS entries must be IPv4 addresses: %q", value)
		}
		normalized := ip.To4().String()
		if !seen[normalized] {
			seen[normalized] = true
			resolvers = append(resolvers, normalized)
		}
	}
	return resolvers, nil
}

func firstConfigured(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func setOrDelete(env map[string]string, key, value string) {
	if value == "" {
		delete(env, key)
		return
	}
	env[key] = value
}
