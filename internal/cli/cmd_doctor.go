package cli

import (
	"context"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"time"

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
		if b.AgentState != "running" {
			return fmt.Errorf("doctor %s: box is not running; run: tx9 start %s", name, name)
		}

		tok, err := box.Token(name)
		if err != nil {
			return fmt.Errorf("doctor %s: %w", name, err)
		}

		guestErr := box.HB(ctx, cli, b, tok, os.Stdout, os.Stderr, "doctor")

		port, portErr := box.HostPort(ctx, cli, b)
		var probeErr error
		if portErr != nil {
			probeErr = fmt.Errorf("host-side probe: %w", portErr)
		} else {
			probeErr = probeHostPort(port)
			if probeErr == nil {
				fmt.Printf("ok   host executor endpoint reachable on port %s\n", port)
			}
		}

		if guestErr != nil || probeErr != nil {
			return fmt.Errorf("doctor %s: guest=%v host=%v", name, guestErr, probeErr)
		}
		fmt.Printf("doctor passed for %s\n", name)
		return nil
	})
}

// probeHostPort mirrors boxd's cmd_doctor host-side retry loop (dossier
// §5.2): up to 6 attempts, 3s connect timeout, 3s sleep between attempts —
// the executor daemon needs a few seconds after `start` before it's
// actually listening (dossier §10 gotcha #2).
func probeHostPort(port string) error {
	const attempts = 6
	const connectTimeout = 3 * time.Second
	const retryWait = 3 * time.Second

	url := fmt.Sprintf("http://127.0.0.1:%s/", port)
	client := &http.Client{
		Timeout: connectTimeout,
		Transport: &http.Transport{
			DialContext: (&net.Dialer{Timeout: connectTimeout}).DialContext,
		},
	}

	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		resp, err := client.Get(url)
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
			time.Sleep(retryWait)
		}
	}
	return fmt.Errorf("executor dashboard unreachable on 127.0.0.1:%s after %d attempts: %w", port, attempts, lastErr)
}
