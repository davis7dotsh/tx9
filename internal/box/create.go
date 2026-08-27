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

// CreateOpts parameterizes Create.
type CreateOpts struct {
	Name        string
	Image       string // e.g. "tx9-box:dev"
	Token       string
	Executor    ExecutorConfig
	Resources   Resources
	AgentMounts []AgentMount
	NoStart     bool // create network/volumes/containers but do not start them (import path)
}

// Create materializes a box's network, volumes, and both containers per the
// dossier §1 topology, using tx9-* naming instead of boxd's hbl-*. Network
// and volume creation are idempotent (ensureNetwork/ensureVolume), so
// upgrade can call Create again against a box whose network/volumes already
// exist without erroring — only the containers (removed by the caller
// first) are created fresh each time.
func Create(ctx context.Context, cli *docker.Client, opts CreateOpts) (*Box, error) {
	name := opts.Name
	resources := opts.Resources
	if err := resources.Validate(); err != nil {
		return nil, fmt.Errorf("box: create %s: resources: %w", name, err)
	}
	_, executorName := ContainerNames(name)
	netName := NetworkName(name)
	agentVol, execVol := VolumeNames(name)
	ver := version.Version
	externalBinds, supplementalGroups, err := prepareAgentMounts(opts.AgentMounts)
	if err != nil {
		return nil, fmt.Errorf("box: create %s: %w", name, err)
	}

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

	agentSpec := newAgentContainerSpecWithResources(name, opts.Image, opts.Token, ver, netID, agentVol, externalBinds, supplementalGroups, resources.Agent)
	agentID, err := cli.ContainerCreate(ctx, agentSpec)
	if err != nil {
		return nil, fmt.Errorf("box: create %s: agent: %w", name, err)
	}

	execPort := nat.Port(executorPort)
	executorEnv := []string{
		"EXECUTOR_MCP_TOKEN=" + opts.Token,
		"TX9_BOX_NAME=" + name,
	}
	if opts.Executor.WebBaseURL != "" {
		executorEnv = append(executorEnv, "EXECUTOR_WEB_BASE_URL="+opts.Executor.WebBaseURL)
	}
	executorLabels := docker.BoxLabels(name, ver, docker.RoleExecutor)
	if opts.Executor.WebBaseURL != "" {
		executorLabels[docker.LabelExecutorWebBaseURL] = opts.Executor.WebBaseURL
	}
	publishIP := opts.Executor.PublishIP
	if publishIP == "" {
		publishIP = "0.0.0.0"
	}
	executorSpec := docker.ContainerSpec{
		Name:           executorName,
		Image:          opts.Image,
		Entrypoint:     []string{"/opt/hermes-box/bin/executor-entrypoint"},
		Env:            executorEnv,
		Labels:         executorLabels,
		NetworkID:      netID,
		NetworkAliases: []string{"executor"},
		Binds:          []string{execVol + ":/data"},
		ExposedPorts:   nat.PortSet{execPort: struct{}{}},
		PortBindings:   nat.PortMap{execPort: []nat.PortBinding{{HostIP: publishIP, HostPort: opts.Executor.PublishPort}}},
		DNS:            opts.Executor.DNS,
		Sysctls:        ipv6DisableSysctl,
		NanoCPUs:       resources.Executor.NanoCPUs,
		MemoryBytes:    resources.Executor.MemoryBytes,
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
		Name:               name,
		AgentID:            agentID,
		ExecutorID:         executorID,
		AgentState:         "created",
		ExecutorState:      "created",
		ExecutorWebBaseURL: opts.Executor.WebBaseURL,
		Version:            ver,
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

func newAgentContainerSpec(name, image, token, ver, netID, agentVol string, externalBinds, supplementalGroups []string) docker.ContainerSpec {
	return newAgentContainerSpecWithResources(
		name, image, token, ver, netID, agentVol, externalBinds, supplementalGroups,
		DefaultResources().Agent,
	)
}

func newAgentContainerSpecWithResources(name, image, token, ver, netID, agentVol string, externalBinds, supplementalGroups []string, resources ContainerResources) docker.ContainerSpec {
	binds := append([]string{agentVol + ":/data"}, externalBinds...)
	agentName, _ := ContainerNames(name)
	env := []string{
		"EXECUTOR_HOST=executor",
		"BOXD_EXECUTOR_TOKEN=" + token,
		"BOX_EXECUTOR_BRIDGE_PORT=4788",
		"BOX_HERMES_BRIDGE_PORT=0",
		"TX9_BOX_NAME=" + name,
	}
	if len(supplementalGroups) > 0 {
		env = append(env, "TX9_AGENT_MOUNT_GIDS="+strings.Join(supplementalGroups, ","))
	}
	return docker.ContainerSpec{
		Name:           agentName,
		Image:          image,
		Entrypoint:     []string{"/opt/hermes-box/bin/entrypoint"},
		Env:            env,
		Labels:         docker.BoxLabels(name, ver, docker.RoleAgent),
		NetworkID:      netID,
		NetworkAliases: []string{"agent"},
		Binds:          binds,
		GroupAdd:       supplementalGroups,
		Sysctls:        ipv6DisableSysctl,
		NanoCPUs:       resources.NanoCPUs,
		MemoryBytes:    resources.MemoryBytes,
	}
}

// RecreateAgent replaces only the disposable agent container while keeping
// the Executor container, network, and both durable volumes intact. Its image
// and tx9 version label are inherited from the existing container so changing
// mounts does not implicitly upgrade the box. A stopped box stays stopped:
// starting the agent as a side effect would run hb-workload's reconcile loop,
// which can start the Hermes gateway on a box that was stopped precisely to
// keep that gateway offline (single-writer discipline).
func RecreateAgent(ctx context.Context, cli *docker.Client, b *Box, token string, mounts []AgentMount) (bool, error) {
	if b.AgentID == "" {
		return false, fmt.Errorf("box: recreate agent %s: agent container missing; run `tx9 upgrade %s` to recreate it", b.Name, b.Name)
	}
	externalBinds, supplementalGroups, err := prepareAgentMounts(mounts)
	if err != nil {
		return false, fmt.Errorf("box: recreate agent %s: %w", b.Name, err)
	}
	inspect, err := cli.ContainerInspect(ctx, b.AgentID)
	if err != nil {
		return false, fmt.Errorf("box: recreate agent %s: %w", b.Name, err)
	}
	image := inspect.Config.Image
	if image == "" {
		return false, fmt.Errorf("box: recreate agent %s: existing container has no image reference", b.Name)
	}
	if inspect.HostConfig == nil {
		return false, fmt.Errorf("box: recreate agent %s: existing container inspect response has no host config", b.Name)
	}
	resources := ContainerResources{
		NanoCPUs:    inspect.HostConfig.NanoCPUs,
		MemoryBytes: inspect.HostConfig.Memory,
	}

	wasRunning := b.AgentState == "running"
	// Current images register TX9_AGENT_MOUNT_GIDS in their entrypoint on
	// every boot; only images predating that need an exec-based group setup
	// against a running replacement. Detect which case this is before any
	// destructive step, so an unsupportable combination (old image, stopped
	// box) fails while the existing container is still intact — and so the
	// CLI never races the entrypoint's own groupadd on current images.
	entrypointConfiguresGroups := true
	if len(supplementalGroups) > 0 {
		entrypointConfiguresGroups, err = imageConfiguresMountGroups(ctx, cli, image)
		if err != nil {
			return false, fmt.Errorf("box: recreate agent %s: %w", b.Name, err)
		}
		if !entrypointConfiguresGroups && !wasRunning {
			return false, fmt.Errorf("box: recreate agent %s: this box's image predates in-boot mount group setup and the box is stopped; start it (`tx9 start %s`) and re-run the mount command, or `tx9 upgrade %s`", b.Name, b.Name, b.Name)
		}
	}

	netID, err := ensureNetwork(ctx, cli, NetworkName(b.Name), b.Name, b.Version)
	if err != nil {
		return false, fmt.Errorf("box: recreate agent %s: %w", b.Name, err)
	}
	agentVol, _ := VolumeNames(b.Name)
	if _, err := ensureVolume(ctx, cli, agentVol, b.Name, b.Version); err != nil {
		return false, fmt.Errorf("box: recreate agent %s: %w", b.Name, err)
	}

	if wasRunning {
		if err := cli.ContainerStop(ctx, b.AgentID, nil); err != nil {
			return false, fmt.Errorf("box: recreate agent %s: %w", b.Name, err)
		}
	}
	if err := cli.ContainerRemove(ctx, b.AgentID, true); err != nil {
		return false, fmt.Errorf("box: recreate agent %s: %w", b.Name, err)
	}

	spec := newAgentContainerSpecWithResources(b.Name, image, token, b.Version, netID, agentVol, externalBinds, supplementalGroups, resources)
	agentID, err := cli.ContainerCreate(ctx, spec)
	if err != nil {
		return false, fmt.Errorf("box: recreate agent %s: container removed but replacement creation failed; run `tx9 upgrade %s` to recreate it after fixing the cause: %w", b.Name, b.Name, err)
	}
	b.AgentID = agentID
	b.AgentState = "created"
	if wasRunning {
		if err := cli.ContainerStart(ctx, agentID); err != nil {
			return wasRunning, fmt.Errorf("box: recreate agent %s: replacement created but failed to start: %w", b.Name, err)
		}
		b.AgentState = "running"
	}
	if len(supplementalGroups) > 0 && !entrypointConfiguresGroups {
		// Old image on a running box: register the groups via exec, then
		// restart so runuser rebuilds every long-running agent process with
		// the new group membership.
		if err := configureAgentMountGroups(ctx, cli, agentID, supplementalGroups); err != nil {
			return wasRunning, fmt.Errorf("box: recreate agent %s: %w", b.Name, err)
		}
		if err := cli.ContainerStop(ctx, agentID, nil); err != nil {
			return wasRunning, fmt.Errorf("box: recreate agent %s: restart after mount group setup: %w", b.Name, err)
		}
		b.AgentState = "exited"
		if err := cli.ContainerStart(ctx, agentID); err != nil {
			return true, fmt.Errorf("box: recreate agent %s: mount groups configured but restart failed: %w", b.Name, err)
		}
		b.AgentState = "running"
	}
	return wasRunning, nil
}

// imageConfiguresMountGroups reports whether image's entrypoint registers
// TX9_AGENT_MOUNT_GIDS itself at boot. Grepping the shipped script is exact
// regardless of how the image is tagged, and works for stopped boxes.
func imageConfiguresMountGroups(ctx context.Context, cli *docker.Client, image string) (bool, error) {
	exitCode, err := cli.RunEphemeral(ctx, docker.EphemeralOpts{
		Image:      image,
		Entrypoint: []string{"grep"},
		Cmd:        []string{"-q", "TX9_AGENT_MOUNT_GIDS", "/opt/hermes-box/bin/entrypoint"},
		Stdout:     io.Discard,
		Stderr:     io.Discard,
	})
	if err != nil {
		return false, fmt.Errorf("detect entrypoint mount group support in %s: %w", image, err)
	}
	switch exitCode {
	case 0:
		return true, nil
	case 1:
		return false, nil
	default:
		// grep exits 2 when the entrypoint file itself is missing or
		// unreadable — an inspection failure, not an old image.
		return false, fmt.Errorf("detect entrypoint mount group support in %s: grep exited %d reading the image entrypoint", image, exitCode)
	}
}

const configureAgentMountGroupScript = `set -euo pipefail
gid="$1"
group="$(getent group "$gid" | cut -d: -f1 || true)"
if [ -z "$group" ]; then
  group="tx9-mount-$gid"
  groupadd --gid "$gid" "$group"
fi
usermod --append --groups "$group" agent
`

func configureAgentMountGroups(ctx context.Context, cli *docker.Client, containerID string, groups []string) error {
	for _, group := range groups {
		res, err := cli.Exec(ctx, containerID, []string{
			"bash", "-c", configureAgentMountGroupScript, "tx9-mount-group", group,
		}, nil, "root")
		if err != nil {
			return fmt.Errorf("configure mount group %s: %w", group, err)
		}
		if res.ExitCode != 0 {
			return fmt.Errorf("configure mount group %s: exit %d: %s", group, res.ExitCode, strings.TrimSpace(res.Stderr))
		}
	}
	return nil
}

// AgentQuiesced reports whether the box's agent is quiesced (`hb pause`,
// the single-writer safety gate). Unlike calling `hb is-paused` through HB —
// where "not paused" (exit 1) and "exec failed" are the same error — this
// maps the exit code inside the container so a transient exec failure is an
// error, never mistaken for "active".
func AgentQuiesced(ctx context.Context, cli *docker.Client, b *Box, token string) (bool, error) {
	if b.AgentID == "" {
		return false, fmt.Errorf("box: quiesce check %s: agent container missing", b.Name)
	}
	cmd := []string{
		"runuser", "-u", "agent", "--",
		"env", "HOME=/data/home/agent",
		"EXECUTOR_HOST=executor",
		"BOXD_EXECUTOR_TOKEN=" + token,
		"bash", "--noprofile", "--norc", "-c",
		`. /etc/profile.d/hermes-box.sh; if hb is-paused; then echo paused; else rc=$?; [ "$rc" -eq 1 ] && echo active || exit "$rc"; fi`,
	}
	res, err := cli.Exec(ctx, b.AgentID, cmd, nil, "root")
	if err != nil {
		return false, fmt.Errorf("box: quiesce check %s: %w", b.Name, err)
	}
	if res.ExitCode != 0 {
		return false, fmt.Errorf("box: quiesce check %s: exit %d: %s", b.Name, res.ExitCode, strings.TrimSpace(res.Stderr))
	}
	switch strings.TrimSpace(res.Stdout) {
	case "paused":
		return true, nil
	case "active":
		return false, nil
	default:
		return false, fmt.Errorf("box: quiesce check %s: unexpected output %q", b.Name, strings.TrimSpace(res.Stdout))
	}
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
			if rmErr := removeOwnedContainer(ctx, cli, b.AgentID, name); rmErr != nil {
				errs = append(errs, rmErr)
			}
		}
		if b.ExecutorID != "" {
			if rmErr := removeOwnedContainer(ctx, cli, b.ExecutorID, name); rmErr != nil {
				errs = append(errs, rmErr)
			}
		}
	case errors.Is(err, ErrNotFound):
		// Check derived names too, but never delete an unrelated container
		// merely because it happens to have the name we would have used.
		for _, cn := range []string{agentName, executorName} {
			if rmErr := removeOwnedContainer(ctx, cli, cn, name); rmErr != nil {
				errs = append(errs, rmErr)
			}
		}
	default:
		errs = append(errs, err)
	}

	if rmErr := removeOwnedNetwork(ctx, cli, netName, name); rmErr != nil {
		errs = append(errs, rmErr)
	}
	for _, vn := range []string{agentVol, execVol} {
		if rmErr := removeOwnedVolume(ctx, cli, vn, name); rmErr != nil {
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
