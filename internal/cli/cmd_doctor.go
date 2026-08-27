package cli

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/docker/go-connections/nat"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
)

// cmdDoctor implements `tx9 doctor <box>`: in-box `hb doctor` + host-side
// published-port probe (dossier §5). Both must pass.
func cmdDoctor(args []string) error {
	fs := flag.NewFlagSet("doctor", flag.ContinueOnError)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	name, err := requireBoxName(fs, "doctor")
	if err != nil {
		return err
	}

	return withDocker(func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("doctor %s: %w", name, err)
		}
		// Use the aggregate state, not just AgentState: if the executor
		// container is down while the agent is up, DerivedState() != "running"
		// catches it here instead of burning the entire 6x3s host-probe
		// loop below only to fail anyway.
		if b.DerivedState() != "running" {
			return fmt.Errorf("doctor %s: box is not running; run: tx9 start %s", name, name)
		}

		tok, err := box.Token(name)
		if err != nil {
			return fmt.Errorf("doctor %s: %w", name, err)
		}

		guestErr := box.HB(ctx, cli, b, tok, os.Stdout, os.Stderr, "doctor")

		binding, portErr := box.HostBinding(ctx, cli, b)
		var probeErr error
		if portErr != nil {
			probeErr = fmt.Errorf("host-side probe: %w", portErr)
		} else {
			probeErr = probeHostPort(ctx, binding)
			if probeErr == nil {
				fmt.Printf("ok   host executor endpoint reachable at %s\n", hostProbeURL(binding))
			}
		}
		var publicProbeErr error
		if b.ExecutorWebBaseURL != "" {
			publicProbeErr = probeExecutorPublicURL(ctx, b.ExecutorWebBaseURL)
			if publicProbeErr == nil {
				fmt.Printf("ok   executor public URL reachable at %s\n", b.ExecutorWebBaseURL)
			}
		}

		if guestErr != nil || probeErr != nil || publicProbeErr != nil {
			return fmt.Errorf("doctor %s: guest=%v host=%v public=%v", name, guestErr, probeErr, publicProbeErr)
		}
		fmt.Printf("doctor passed for %s\n", name)
		return nil
	})
}

func probeExecutorPublicURL(ctx context.Context, baseURL string) error {
	u, err := url.Parse(baseURL)
	if err != nil {
		return fmt.Errorf("executor public URL %q is invalid: %w", baseURL, err)
	}
	u.Path = "/api/health"
	u.RawPath = ""
	u.RawQuery = ""
	u.Fragment = ""

	client := &http.Client{Timeout: 10 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return fmt.Errorf("executor public health probe %s: %w", u, err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("executor public health probe %s: %w", u, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64))
	if err != nil {
		return fmt.Errorf("executor public health probe %s: %w", u, err)
	}
	if resp.StatusCode != http.StatusOK || strings.TrimSpace(string(body)) != "ok" {
		return fmt.Errorf("executor public health probe %s returned status %d body %q", u, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}

// probeHostPort mirrors boxd's cmd_doctor host-side retry loop (dossier
// §5.2): up to 6 attempts, 3s connect timeout, 3s sleep between attempts —
// the executor daemon needs a few seconds after `start` before it's
// actually listening (dossier §10 gotcha #2).
func hostProbeURL(binding nat.PortBinding) string {
	host := binding.HostIP
	if host == "" || host == "0.0.0.0" {
		host = "127.0.0.1"
	} else if host == "::" {
		host = "::1"
	}
	return "http://" + net.JoinHostPort(host, binding.HostPort) + "/"
}

func probeHostPort(ctx context.Context, binding nat.PortBinding) error {
	const attempts = 6
	const connectTimeout = 3 * time.Second
	const retryWait = 3 * time.Second

	url := hostProbeURL(binding)
	client := &http.Client{
		Timeout: connectTimeout,
		Transport: &http.Transport{
			DialContext: (&net.Dialer{Timeout: connectTimeout}).DialContext,
		},
	}
	defer client.CloseIdleConnections()

	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return err
		}
		resp, err := client.Do(req)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode < 400 {
				return nil
			}
			lastErr = fmt.Errorf("unexpected status %d from %s", resp.StatusCode, url)
		} else {
			lastErr = err
		}
		if attempt < attempts {
			timer := time.NewTimer(retryWait)
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
		}
	}
	return fmt.Errorf("executor dashboard unreachable at %s after %d attempts: %w", url, attempts, lastErr)
}
