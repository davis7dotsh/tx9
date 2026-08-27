// Package box implements the tx9 box lifecycle: deriving names for a box's
// Docker objects, reconstructing box state from daemon labels, and driving
// the container topology (dossier §1) through internal/docker's Engine API
// wrapper. It is the shared contract between the lifecycle commands
// (create/list/enter/start/stop/open/doctor/delete/prune/upgrade) and the
// backup/import commands, which only ever go through this package's
// exported API, never internal/docker directly.
package box

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"sort"
	"strings"

	dockernetwork "github.com/docker/docker/api/types/network"
	dockerclient "github.com/docker/docker/client"
	"github.com/docker/go-connections/nat"

	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/state"
)

// ErrNotFound is wrapped into the error Get/Exists return when no
// tx9-labeled container exists for a given box name.
var ErrNotFound = errors.New("box not found")

// executorPort is the container-side port the executor daemon always binds
// (dossier §1.1/§1.4 — fixed, never configurable).
const executorPort = "4788/tcp"

// Box is a snapshot of one box's state, reconstructed from the daemon's
// tx9-labeled containers (decision 2, tx9-cli-design.md: ~/.tx9 is a cache,
// the daemon's labels are the source of truth).
type Box struct {
	Name               string
	AgentID            string // container ID, "" if missing
	ExecutorID         string
	AgentState         string // docker state string: running/exited/...
	ExecutorState      string
	ExecutorWebBaseURL string
	Version            string // tx9.version label value
}

// DerivedState collapses AgentState/ExecutorState into one of
// running/stopped/mixed/crashed for display (tx9 list).
func (b Box) DerivedState() string {
	if b.AgentID == "" || b.ExecutorID == "" {
		return "crashed"
	}
	agentUp := b.AgentState == "running"
	execUp := b.ExecutorState == "running"
	switch {
	case agentUp && execUp:
		return "running"
	case !agentUp && !execUp:
		return "stopped"
	default:
		return "mixed"
	}
}

// ContainerNames returns the two container names tx9 mints for box name:
// "tx9-<name>-agent" and "tx9-<name>-executor".
func ContainerNames(name string) (agent, executor string) {
	return "tx9-" + name + "-agent", "tx9-" + name + "-executor"
}

// NetworkName returns the per-box private bridge network name: "tx9-<name>".
func NetworkName(name string) string {
	return "tx9-" + name
}

// VolumeNames returns the two named volumes tx9 mints for box name:
// "tx9-<name>-agent-data" (the box's durable identity) and
// "tx9-<name>-exec-data" (scratch, dossier §12 — never backed up).
func VolumeNames(name string) (agentData, execData string) {
	return "tx9-" + name + "-agent-data", "tx9-" + name + "-exec-data"
}

// List returns every box this daemon knows about, reconstructed purely from
// tx9=1-labeled containers (order: sorted by name).
func List(ctx context.Context, cli *docker.Client) ([]Box, error) {
	containers, err := cli.ListBoxContainers(ctx)
	if err != nil {
		return nil, fmt.Errorf("box: list: %w", err)
	}

	byName := map[string]*Box{}
	var order []string
	for _, c := range containers {
		name := c.Labels[docker.LabelBox]
		if name == "" {
			continue
		}
		b, ok := byName[name]
		if !ok {
			b = &Box{Name: name}
			byName[name] = b
			order = append(order, name)
		}
		if v := c.Labels[docker.LabelVersion]; v != "" {
			b.Version = v
		}
		switch c.Labels[docker.LabelRole] {
		case docker.RoleAgent:
			b.AgentID = c.ID
			b.AgentState = c.State
		case docker.RoleExecutor:
			b.ExecutorID = c.ID
			b.ExecutorState = c.State
			b.ExecutorWebBaseURL = c.Labels[docker.LabelExecutorWebBaseURL]
		}
	}

	sort.Strings(order)
	boxes := make([]Box, 0, len(order))
	for _, name := range order {
		boxes = append(boxes, *byName[name])
	}
	return boxes, nil
}

// Get returns the box named name, or an error wrapping ErrNotFound if no
// tx9-labeled container exists for it.
func Get(ctx context.Context, cli *docker.Client, name string) (*Box, error) {
	boxes, err := List(ctx, cli)
	if err != nil {
		return nil, err
	}
	for i := range boxes {
		if boxes[i].Name == name {
			return &boxes[i], nil
		}
	}
	return nil, fmt.Errorf("box %q: %w", name, ErrNotFound)
}

// Exists reports whether a box named name has any tx9-labeled container on
// this daemon.
func Exists(ctx context.Context, cli *docker.Client, name string) (bool, error) {
	_, err := Get(ctx, cli, name)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, ErrNotFound) {
		return false, nil
	}
	return false, err
}

// Token returns the box's executor bearer token from ~/.tx9/boxes/<name>.env
// (dossier §2.2 — the host-side cache; the daemon has no label for secrets).
func Token(name string) (string, error) {
	env, err := state.ReadBoxEnv(name)
	if err != nil {
		return "", fmt.Errorf("box: token %s: %w", name, err)
	}
	tok := env["EXECUTOR_MCP_TOKEN"]
	if tok == "" {
		return "", fmt.Errorf("box: token %s: EXECUTOR_MCP_TOKEN not found in ~/.tx9/boxes/%s.env", name, name)
	}
	return tok, nil
}

// Start starts both containers, executor first so the agent's dependent
// services find it already listening (mirrors compose's depends_on, dossier
// §1.1).
func Start(ctx context.Context, cli *docker.Client, b *Box) error {
	if b.AgentID == "" || b.ExecutorID == "" {
		return fmt.Errorf("box: start %s: missing container(s) (agent=%q executor=%q)", b.Name, b.AgentID, b.ExecutorID)
	}
	if err := cli.ContainerStart(ctx, b.ExecutorID); err != nil {
		return fmt.Errorf("box: start %s: executor: %w", b.Name, err)
	}
	if err := cli.ContainerStart(ctx, b.AgentID); err != nil {
		return fmt.Errorf("box: start %s: agent: %w", b.Name, err)
	}
	return nil
}

// Stop stops both containers, agent first (the reverse of Start) so it gets
// a clean chance to shut down before its executor dependency disappears.
func Stop(ctx context.Context, cli *docker.Client, b *Box) error {
	var errs []error
	if b.AgentID != "" {
		if err := cli.ContainerStop(ctx, b.AgentID, nil); err != nil {
			errs = append(errs, fmt.Errorf("agent: %w", err))
		}
	}
	if b.ExecutorID != "" {
		if err := cli.ContainerStop(ctx, b.ExecutorID, nil); err != nil {
			errs = append(errs, fmt.Errorf("executor: %w", err))
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("box: stop %s: %w", b.Name, errors.Join(errs...))
	}
	return nil
}

// HostPort returns the published host port of the executor's 4788/tcp
// (dossier §1.4 — Docker auto-assigns this at container start since the
// spec pins no host port).
func HostPort(ctx context.Context, cli *docker.Client, b *Box) (string, error) {
	if b.ExecutorID == "" {
		return "", fmt.Errorf("box: host port %s: executor container missing", b.Name)
	}
	inspect, err := cli.ContainerInspect(ctx, b.ExecutorID)
	if err != nil {
		return "", fmt.Errorf("box: host port %s: %w", b.Name, err)
	}
	bindings, ok := inspect.NetworkSettings.Ports[nat.Port(executorPort)]
	if !ok || len(bindings) == 0 {
		return "", fmt.Errorf("box: host port %s: executor port %s not published (is the box running?)", b.Name, executorPort)
	}
	return bindings[0].HostPort, nil
}

// URLHost returns the host tx9 prints in dashboard/open URLs: TX9_URL_HOST
// env override, then the machine's Tailscale IP when tailscale is set up,
// then the machine's primary LAN IP, then hostname. IPs beat hostnames here
// because these URLs are opened from other machines, where a bare hostname
// often doesn't resolve.
func URLHost() string {
	if h := os.Getenv("TX9_URL_HOST"); h != "" {
		return h
	}
	if ip := tailscaleIP(); ip != "" {
		return ip
	}
	if ip := outboundIP(); ip != "" {
		return ip
	}
	if h, err := os.Hostname(); err == nil && h != "" {
		return h
	}
	return "localhost"
}

// tailscaleCGNAT is the 100.64.0.0/10 range Tailscale assigns node IPs from.
var tailscaleCGNAT = net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

// tailscaleIP returns this machine's Tailscale IPv4 address, or "" when no
// interface carries one. Detected by address range rather than by shelling
// out to the tailscale CLI, so it works regardless of how tailscaled was
// installed.
func tailscaleIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	for _, addr := range addrs {
		ipnet, ok := addr.(*net.IPNet)
		if !ok {
			continue
		}
		ip4 := ipnet.IP.To4()
		if ip4 != nil && tailscaleCGNAT.Contains(ip4) {
			return ip4.String()
		}
	}
	return ""
}

// outboundIP returns the machine's primary IPv4 address — the source address
// the kernel picks for outbound traffic. The UDP "connection" never sends a
// packet; it only runs route selection, which is exactly the answer we want
// (and skips loopback and docker bridge addresses that a plain interface
// scan couldn't tell apart from the real LAN address).
func outboundIP() string {
	conn, err := net.Dial("udp4", "192.0.2.1:9") // TEST-NET-1, never routed
	if err != nil {
		return ""
	}
	defer conn.Close()
	if addr, ok := conn.LocalAddr().(*net.UDPAddr); ok && addr.IP.To4() != nil {
		return addr.IP.String()
	}
	return ""
}

// DashboardURL is the box's unauthenticated dashboard URL (no token) —
// what `tx9 create` prints (dossier §3 step 9): meant to be shared/logged
// freely.
func DashboardURL(port, webBaseURL string) string {
	if webBaseURL != "" {
		return strings.TrimRight(webBaseURL, "/") + "/"
	}
	return fmt.Sprintf("http://%s:%s/", URLHost(), port)
}

// OpenURL is the box's authenticated dashboard URL, with the bearer token
// embedded in the query string (dossier §4) — what `tx9 open` prints: a
// one-shot secret, not meant for logs.
func OpenURL(port, token, webBaseURL string) (string, error) {
	u, err := url.Parse(DashboardURL(port, webBaseURL))
	if err != nil {
		return "", fmt.Errorf("box: open URL: configured web base URL %q is invalid: %w", webBaseURL, err)
	}
	query := u.Query()
	query.Set("_token", token)
	u.RawQuery = query.Encode()
	return u.String(), nil
}

// ensureNetwork returns the per-box network's ID, creating it if absent so
// Create is idempotent for this object (dossier's upgrade path recreates
// containers but keeps the network).
func ensureNetwork(ctx context.Context, cli *docker.Client, netName, boxName, ver string) (string, error) {
	if insp, err := cli.Raw().NetworkInspect(ctx, netName, dockernetwork.InspectOptions{}); err == nil {
		if !ownedByBox(insp.Labels, boxName) {
			return "", fmt.Errorf("refusing to reuse network %s: it is not owned by box %s", netName, boxName)
		}
		return insp.ID, nil
	} else if !dockerclient.IsErrNotFound(err) {
		return "", fmt.Errorf("network inspect %s: %w", netName, err)
	}
	id, err := cli.NetworkCreate(ctx, netName, docker.BoxLabels(boxName, ver, ""))
	if err != nil {
		return "", err
	}
	return id, nil
}

// ensureVolume returns volName, creating it if absent so Create is
// idempotent for volumes (same rationale as ensureNetwork).
func ensureVolume(ctx context.Context, cli *docker.Client, volName, boxName, ver string) (string, error) {
	if insp, err := cli.Raw().VolumeInspect(ctx, volName); err == nil {
		if !ownedByBox(insp.Labels, boxName) {
			return "", fmt.Errorf("refusing to reuse volume %s: it is not owned by box %s", volName, boxName)
		}
		return volName, nil
	} else if !dockerclient.IsErrNotFound(err) {
		return "", fmt.Errorf("volume inspect %s: %w", volName, err)
	}
	return cli.VolumeCreate(ctx, volName, docker.BoxLabels(boxName, ver, ""))
}
