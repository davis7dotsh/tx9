package box

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	dockerclient "github.com/docker/docker/client"
	"github.com/docker/go-connections/nat"

	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/state"
	"github.com/davis7dotsh/tx9/internal/version"
)

// ipv6DisableSysctl is applied to both containers (dossier §10 gotcha #1):
// the executor daemon binds "localhost", which resolves to ::1 first in a
// default Docker container, so health checks against 127.0.0.1 would see a
// closed port unless IPv6 is disabled in the container's netns.
var ipv6DisableSysctl = map[string]string{"net.ipv6.conf.all.disable_ipv6": "1"}

// CPU/memory limits, ported verbatim from docker/compose.yaml's defaults
// (dossier §1.3/§1.4 live-inspect-confirmed): agent 4 CPUs / 8192 MiB,
// executor 2 CPUs / 2048 MiB.
const (
	agentNanoCPUs       = 4_000_000_000
	agentMemoryBytes    = 8192 * 1024 * 1024
	executorNanoCPUs    = 2_000_000_000
	executorMemoryBytes = 2048 * 1024 * 1024
)

// CreateOpts parameterizes Create.
type CreateOpts struct {
	Name    string
	Image   string // e.g. "tx9-box:dev"
	Token   string
	NoStart bool // create network/volumes/containers but do not start them (import path)
}

// Create materializes a box's network, volumes, and both containers per the
// dossier §1 topology, using tx9-* naming instead of boxd's hbl-*. Network
// and volume creation are idempotent (ensureNetwork/ensureVolume), so
// upgrade can call Create again against a box whose network/volumes already
// exist without erroring — only the containers (removed by the caller
// first) are created fresh each time.
func Create(ctx context.Context, cli *docker.Client, opts CreateOpts) (*Box, error) {
	name := opts.Name
	agentName, executorName := ContainerNames(name)
	netName := NetworkName(name)
	agentVol, execVol := VolumeNames(name)
	ver := version.Version

	netID, err := ensureNetwork(ctx, cli, netName, name, ver)
	if err != nil {
		return nil, fmt.Errorf("box: create %s: %w", name, err)
	}
	if _, err := ensureVolume(ctx, cli, agentVol, name, ver); err != nil {
		return nil, fmt.Errorf("box: create %s: %w", name, err)
	}
	if _, err := ensureVolume(ctx, cli, execVol, name, ver); err != nil {
		return nil, fmt.Errorf("box: create %s: %w", name, err)
	}

	agentSpec := docker.ContainerSpec{
		Name:       agentName,
		Image:      opts.Image,
		Entrypoint: []string{"/opt/hermes-box/bin/entrypoint"},
		Env: []string{
			"EXECUTOR_HOST=executor",
			"BOXD_EXECUTOR_TOKEN=" + opts.Token,
			"BOX_EXECUTOR_BRIDGE_PORT=4788",
			"BOX_HERMES_BRIDGE_PORT=0",
		},
		Labels:         docker.BoxLabels(name, ver, docker.RoleAgent),
		NetworkID:      netID,
		NetworkAliases: []string{"agent"},
		Binds:          []string{agentVol + ":/data"},
		Sysctls:        ipv6DisableSysctl,
		NanoCPUs:       agentNanoCPUs,
		MemoryBytes:    agentMemoryBytes,
	}
	agentID, err := cli.ContainerCreate(ctx, agentSpec)
	if err != nil {
		return nil, fmt.Errorf("box: create %s: agent: %w", name, err)
	}

	execPort := nat.Port(executorPort)
	executorSpec := docker.ContainerSpec{
		Name:           executorName,
		Image:          opts.Image,
		Entrypoint:     []string{"/opt/hermes-box/bin/executor-entrypoint"},
		Env:            []string{"EXECUTOR_MCP_TOKEN=" + opts.Token},
		Labels:         docker.BoxLabels(name, ver, docker.RoleExecutor),
		NetworkID:      netID,
		NetworkAliases: []string{"executor"},
		Binds:          []string{execVol + ":/data"},
		ExposedPorts:   nat.PortSet{execPort: struct{}{}},
		PortBindings:   nat.PortMap{execPort: []nat.PortBinding{{HostIP: "0.0.0.0", HostPort: ""}}},
		Sysctls:        ipv6DisableSysctl,
		NanoCPUs:       executorNanoCPUs,
		MemoryBytes:    executorMemoryBytes,
	}
	executorID, err := cli.ContainerCreate(ctx, executorSpec)
	if err != nil {
		// The agent container was already created above; leaving it
		// behind on this failure path leaks it, which matters most on
		// the upgrade path where the caller doesn't call Destroy on
		// error. Best-effort force-remove it (ignoring not-found) before
		// returning.
		if rmErr := cli.ContainerRemove(ctx, agentID, true); rmErr != nil && !dockerclient.IsErrNotFound(rmErr) {
			return nil, fmt.Errorf("box: create %s: executor: %w (also failed to remove leaked agent container: %v)", name, err, rmErr)
		}
		return nil, fmt.Errorf("box: create %s: executor: %w", name, err)
	}

	b := &Box{
		Name:          name,
		AgentID:       agentID,
		ExecutorID:    executorID,
		AgentState:    "created",
		ExecutorState: "created",
		Version:       ver,
	}

	if !opts.NoStart {
		if err := Start(ctx, cli, b); err != nil {
			return b, fmt.Errorf("box: create %s: %w", name, err)
		}
		b.AgentState = "running"
		b.ExecutorState = "running"
	}
	return b, nil
}

// HB runs `hb <args...>` inside the agent container, exactly replicating
// boxd's `_guest_hb` remote-control pattern (dossier §3): `runuser` drops to
// the agent user, and BOXD_EXECUTOR_TOKEN takes precedence over whatever
// stale token might be baked into the box's restored on-disk
// executor-mcp.env (dossier §2.3/§7.4 — the real bug this env override
// exists to fix).
func HB(ctx context.Context, cli *docker.Client, b *Box, token string, stdout, stderr io.Writer, args ...string) error {
	if b.AgentID == "" {
		return fmt.Errorf("box: hb %s %v: agent container missing", b.Name, args)
	}
	cmd := append([]string{
		"runuser", "-u", "agent", "--",
		"env", "HOME=/data/home/agent",
		"EXECUTOR_HOST=executor",
		"BOXD_EXECUTOR_TOKEN=" + token,
		"bash", "--noprofile", "--norc", "-c",
		`. /etc/profile.d/hermes-box.sh; exec hb "$@"`,
		"hb",
	}, args...)

	res, err := cli.Exec(ctx, b.AgentID, cmd, nil, "")
	if err != nil {
		return fmt.Errorf("box: hb %s %v: %w", b.Name, args, err)
	}
	if stdout != nil && res.Stdout != "" {
		io.WriteString(stdout, res.Stdout)
	}
	if stderr != nil && res.Stderr != "" {
		io.WriteString(stderr, res.Stderr)
	}
	if res.ExitCode != 0 {
		return fmt.Errorf("box: hb %s %v: exit %d: %s", b.Name, args, res.ExitCode, strings.TrimSpace(res.Stderr))
	}
	return nil
}

// PrepareRuntime is the post-create/post-upgrade readiness gate (dossier §3
// step 8 / _prepare_runtime): `hb up` gets up to 6 attempts with a 15s sleep
// between them, because a freshly-started container needs real wall-clock
// time before its daemon lock holders (hb-workload's reconcile loop) settle
// (dossier §10 gotcha #2). Only once `hb up` succeeds does it run
// `hb wire-once` then `hb doctor`.
func PrepareRuntime(ctx context.Context, cli *docker.Client, b *Box, token string, out io.Writer) error {
	const attempts = 6
	const retryWait = 15 * time.Second

	var upErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		upErr = HB(ctx, cli, b, token, out, out, "up")
		if upErr == nil {
			break
		}
		fmt.Fprintf(out, "box %s: hb up attempt %d/%d failed: %v\n", b.Name, attempt, attempts, upErr)
		if attempt < attempts {
			select {
			case <-time.After(retryWait):
			case <-ctx.Done():
				return fmt.Errorf("box: prepare runtime %s: %w", b.Name, ctx.Err())
			}
		}
	}
	if upErr != nil {
		return fmt.Errorf("box: prepare runtime %s: hb up did not succeed after %d attempts: %w", b.Name, attempts, upErr)
	}

	if err := HB(ctx, cli, b, token, out, out, "wire-once"); err != nil {
		return fmt.Errorf("box: prepare runtime %s: wire-once: %w", b.Name, err)
	}
	if err := HB(ctx, cli, b, token, out, out, "doctor"); err != nil {
		return fmt.Errorf("box: prepare runtime %s: doctor: %w", b.Name, err)
	}
	return nil
}

// Destroy removes a box's containers (force), network, volumes, and cached
// token file. It tolerates partial existence (e.g. a box that failed
// mid-create) — every step is best-effort and errors are collected rather
// than short-circuiting, so a half-created box never gets "stuck"
// undeletable.
func Destroy(ctx context.Context, cli *docker.Client, name string) error {
	agentName, executorName := ContainerNames(name)
	netName := NetworkName(name)
	agentVol, execVol := VolumeNames(name)

	var errs []error

	b, err := Get(ctx, cli, name)
	switch {
	case err == nil:
		if b.AgentID != "" {
			if rmErr := cli.ContainerRemove(ctx, b.AgentID, true); rmErr != nil && !dockerclient.IsErrNotFound(rmErr) {
				errs = append(errs, rmErr)
			}
		}
		if b.ExecutorID != "" {
			if rmErr := cli.ContainerRemove(ctx, b.ExecutorID, true); rmErr != nil && !dockerclient.IsErrNotFound(rmErr) {
				errs = append(errs, rmErr)
			}
		}
	case errors.Is(err, ErrNotFound):
		// No labeled containers found via List (e.g. labels never got
		// applied because create failed very early) — fall back to
		// removing by the names we would have minted, best-effort.
		for _, cn := range []string{agentName, executorName} {
			if rmErr := cli.ContainerRemove(ctx, cn, true); rmErr != nil && !dockerclient.IsErrNotFound(rmErr) {
				errs = append(errs, rmErr)
			}
		}
	default:
		errs = append(errs, err)
	}

	if rmErr := cli.NetworkRemove(ctx, netName); rmErr != nil && !dockerclient.IsErrNotFound(rmErr) {
		errs = append(errs, rmErr)
	}
	for _, vn := range []string{agentVol, execVol} {
		if rmErr := cli.VolumeRemove(ctx, vn, true); rmErr != nil && !dockerclient.IsErrNotFound(rmErr) {
			errs = append(errs, rmErr)
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("box: destroy %s: %w", name, errors.Join(errs...))
	}

	// Only drop the token env file once every other removal above
	// succeeded — removing it unconditionally would strand a box that
	// still exists (e.g. because a volume remove failed) without the
	// token it needs.
	if rmErr := state.RemoveBoxEnv(name); rmErr != nil {
		return fmt.Errorf("box: destroy %s: %w", name, rmErr)
	}
	return nil
}
