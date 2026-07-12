// Package docker is a thin wrapper over the official Docker Engine Go SDK
// (decision 8, tx9-cli-design.md). It exposes only what box lifecycle
// commands need — images, containers, networks, volumes, exec — behind a
// small struct so a remote daemon (SSH tunnel / DOCKER_HOST) can slot in
// later without restructuring callers.
package docker

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"math"

	dockertypes "github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/build"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/filters"
	"github.com/docker/docker/api/types/image"
	"github.com/docker/docker/api/types/network"
	"github.com/docker/docker/api/types/volume"
	"github.com/docker/docker/client"
	"github.com/docker/docker/pkg/jsonmessage"
	"github.com/docker/docker/pkg/stdcopy"
	"github.com/docker/go-connections/nat"

	"github.com/davis7dotsh/tx9/internal/assets"
)

// Client wraps the Docker Engine API client with tx9-shaped helpers.
type Client struct {
	cli *client.Client
}

// NewClient connects to the Docker daemon from the environment
// (DOCKER_HOST/DOCKER_CERT_PATH/etc, same as the docker CLI) and negotiates
// the API version so it works across a range of daemon versions.
func NewClient(ctx context.Context) (*Client, error) {
	cli, err := client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		return nil, fmt.Errorf("docker: new client: %w", err)
	}
	if _, err := cli.Ping(ctx); err != nil {
		cli.Close()
		return nil, fmt.Errorf("docker: daemon unreachable: %w", err)
	}
	return &Client{cli: cli}, nil
}

// Close releases the underlying HTTP client's connections.
func (c *Client) Close() error {
	return c.cli.Close()
}

// Raw exposes the underlying SDK client for calls this wrapper doesn't
// (yet) cover.
func (c *Client) Raw() *client.Client {
	return c.cli
}

// ImageExists reports whether tag is present in the local image store.
func (c *Client) ImageExists(ctx context.Context, tag string) (bool, error) {
	_, err := c.cli.ImageInspect(ctx, tag)
	if err == nil {
		return true, nil
	}
	if client.IsErrNotFound(err) {
		return false, nil
	}
	return false, fmt.Errorf("docker: image inspect %s: %w", tag, err)
}

// BuildImage builds tag from buildContext (a tar stream — see
// internal/assets.BuildContextTar), streaming daemon build progress as
// human-readable lines to progress.
func (c *Client) BuildImage(ctx context.Context, buildContext io.Reader, tag string, progress io.Writer) error {
	resp, err := c.cli.ImageBuild(ctx, buildContext, build.ImageBuildOptions{
		Tags:       []string{tag},
		Dockerfile: assets.DockerfilePath,
		Remove:     true,
	})
	if err != nil {
		return fmt.Errorf("docker: image build %s: %w", tag, err)
	}
	defer resp.Body.Close()

	if err := jsonmessage.DisplayJSONMessagesStream(resp.Body, progress, 0, false, nil); err != nil {
		return fmt.Errorf("docker: image build %s: %w", tag, err)
	}
	return nil
}

// ListBoxContainers returns every container tx9 has ever labeled
// (LabelManaged), running or not, so `tx9 list` can reconstruct state from
// the daemon alone.
func (c *Client) ListBoxContainers(ctx context.Context) ([]container.Summary, error) {
	f := filters.NewArgs(filters.Arg("label", LabelManaged+"=1"))
	containers, err := c.cli.ContainerList(ctx, container.ListOptions{All: true, Filters: f})
	if err != nil {
		return nil, fmt.Errorf("docker: list containers: %w", err)
	}
	return containers, nil
}

// NetworkCreate creates a private bridge network for a box, with IPv6
// explicitly disabled at the network level (dossier §1.4 — compose's
// default when no IPv6 config is requested; tx9 replicates it explicitly).
func (c *Client) NetworkCreate(ctx context.Context, name string, labels map[string]string) (string, error) {
	enableIPv6 := false
	resp, err := c.cli.NetworkCreate(ctx, name, network.CreateOptions{
		Driver:     "bridge",
		EnableIPv6: &enableIPv6,
		Labels:     labels,
	})
	if err != nil {
		return "", fmt.Errorf("docker: network create %s: %w", name, err)
	}
	return resp.ID, nil
}

// NetworkRemove removes a network by ID or name.
func (c *Client) NetworkRemove(ctx context.Context, id string) error {
	if err := c.cli.NetworkRemove(ctx, id); err != nil {
		return fmt.Errorf("docker: network remove %s: %w", id, err)
	}
	return nil
}

// VolumeCreate creates a named volume.
func (c *Client) VolumeCreate(ctx context.Context, name string, labels map[string]string) (string, error) {
	v, err := c.cli.VolumeCreate(ctx, volume.CreateOptions{Name: name, Labels: labels})
	if err != nil {
		return "", fmt.Errorf("docker: volume create %s: %w", name, err)
	}
	return v.Name, nil
}

// VolumeRemove removes a named volume.
func (c *Client) VolumeRemove(ctx context.Context, name string, force bool) error {
	if err := c.cli.VolumeRemove(ctx, name, force); err != nil {
		return fmt.Errorf("docker: volume remove %s: %w", name, err)
	}
	return nil
}

// VolumeUsage returns byte usage for the requested named volumes from one
// /system/df request. A value of -1 means the daemon cannot report usage for
// that volume (for example, because its driver is not local). With no names,
// usage for every volume returned by the daemon is included.
func (c *Client) VolumeUsage(ctx context.Context, names ...string) (map[string]int64, []string, error) {
	usage, err := c.cli.DiskUsage(ctx, dockertypes.DiskUsageOptions{
		Types: []dockertypes.DiskUsageObject{dockertypes.VolumeObject},
	})
	if err != nil {
		return nil, nil, fmt.Errorf("docker: volume disk usage: %w", err)
	}

	wanted := make(map[string]bool, len(names))
	orderedNames := make([]string, 0, len(names))
	for _, name := range names {
		if name == "" || wanted[name] {
			continue
		}
		wanted[name] = true
		orderedNames = append(orderedNames, name)
	}
	filterByName := len(wanted) > 0

	result := make(map[string]int64, len(names))
	var warnings []string
	for _, v := range usage.Volumes {
		if v == nil || v.Name == "" {
			continue
		}
		if filterByName && !wanted[v.Name] {
			continue
		}
		delete(wanted, v.Name)
		if v.UsageData == nil {
			result[v.Name] = -1
			warnings = append(warnings, fmt.Sprintf("volume %s: Docker did not return usage data", v.Name))
			continue
		}
		result[v.Name] = v.UsageData.Size
		if v.UsageData.Size < 0 {
			warnings = append(warnings, fmt.Sprintf("volume %s: driver %s does not report usage", v.Name, v.Driver))
		}
	}
	for _, name := range orderedNames {
		if !wanted[name] {
			continue
		}
		result[name] = -1
		warnings = append(warnings, fmt.Sprintf("volume %s: not found in Docker disk usage response", name))
	}
	return result, warnings, nil
}

// ContainerSpec describes a container tx9 wants created. It only covers the
// fields the box topology (dossier §1) actually uses — not the full Engine
// API surface.
type ContainerSpec struct {
	Name           string
	Image          string
	Entrypoint     []string
	Env            []string
	Labels         map[string]string
	Hostname       string
	NetworkID      string
	NetworkAliases []string
	Binds          []string // "volume:/container/path" or "volume:/path:ro"
	GroupAdd       []string // supplemental numeric GIDs needed by host bind mounts
	ExposedPorts   nat.PortSet
	PortBindings   nat.PortMap
	DNS            []string
	Sysctls        map[string]string
	NanoCPUs       int64
	MemoryBytes    int64
}

// ContainerCreate creates (but does not start) a container per spec, with
// `--init` and `restart: unless-stopped` baked in (dossier §1.3 — every box
// container uses both).
func (c *Client) ContainerCreate(ctx context.Context, spec ContainerSpec) (string, error) {
	memorySwap, err := defaultMemorySwapLimit(spec.MemoryBytes)
	if err != nil {
		return "", fmt.Errorf("docker: container create %s: %w", spec.Name, err)
	}
	initEnabled := true
	cfg := &container.Config{
		Image:        spec.Image,
		Entrypoint:   spec.Entrypoint,
		Env:          spec.Env,
		Labels:       spec.Labels,
		Hostname:     spec.Hostname,
		ExposedPorts: spec.ExposedPorts,
	}
	hostCfg := &container.HostConfig{
		Binds:        spec.Binds,
		GroupAdd:     spec.GroupAdd,
		PortBindings: spec.PortBindings,
		DNS:          spec.DNS,
		Sysctls:      spec.Sysctls,
		Init:         &initEnabled,
		RestartPolicy: container.RestartPolicy{
			Name: container.RestartPolicyUnlessStopped,
		},
		Resources: container.Resources{
			NanoCPUs:   spec.NanoCPUs,
			Memory:     spec.MemoryBytes,
			MemorySwap: memorySwap,
		},
	}

	var netCfg *network.NetworkingConfig
	if spec.NetworkID != "" {
		netCfg = &network.NetworkingConfig{
			EndpointsConfig: map[string]*network.EndpointSettings{
				spec.NetworkID: {Aliases: spec.NetworkAliases},
			},
		}
	}

	resp, err := c.cli.ContainerCreate(ctx, cfg, hostCfg, netCfg, nil, spec.Name)
	if err != nil {
		return "", fmt.Errorf("docker: container create %s: %w", spec.Name, err)
	}
	return resp.ID, nil
}

// ContainerStart starts a previously-created container.
func (c *Client) ContainerStart(ctx context.Context, id string) error {
	if err := c.cli.ContainerStart(ctx, id, container.StartOptions{}); err != nil {
		return fmt.Errorf("docker: container start %s: %w", id, err)
	}
	return nil
}

// ContainerStop stops a running container (nil timeout uses the daemon
// default grace period).
func (c *Client) ContainerStop(ctx context.Context, id string, timeoutSeconds *int) error {
	if err := c.cli.ContainerStop(ctx, id, container.StopOptions{Timeout: timeoutSeconds}); err != nil {
		return fmt.Errorf("docker: container stop %s: %w", id, err)
	}
	return nil
}

// ContainerRemove removes a container. force also kills it if running.
func (c *Client) ContainerRemove(ctx context.Context, id string, force bool) error {
	if err := c.cli.ContainerRemove(ctx, id, container.RemoveOptions{Force: force, RemoveVolumes: false}); err != nil {
		return fmt.Errorf("docker: container remove %s: %w", id, err)
	}
	return nil
}

// ContainerInspect returns full container state.
func (c *Client) ContainerInspect(ctx context.Context, id string) (container.InspectResponse, error) {
	resp, err := c.cli.ContainerInspect(ctx, id)
	if err != nil {
		return container.InspectResponse{}, fmt.Errorf("docker: container inspect %s: %w", id, err)
	}
	return resp, nil
}

// ContainerUpdateResources updates a container's mutable CPU and memory
// limits in place. Docker may accept an update with non-fatal warnings, so
// callers receive those warnings verbatim for display.
func (c *Client) ContainerUpdateResources(ctx context.Context, id string, nanoCPUs, memoryBytes int64) ([]string, error) {
	memorySwap, err := defaultMemorySwapLimit(memoryBytes)
	if err != nil {
		return nil, fmt.Errorf("docker: container update resources %s: %w", id, err)
	}
	resp, err := c.cli.ContainerUpdate(ctx, id, container.UpdateConfig{
		Resources: container.Resources{
			NanoCPUs:   nanoCPUs,
			Memory:     memoryBytes,
			MemorySwap: memorySwap,
		},
	})
	if err != nil {
		return nil, fmt.Errorf("docker: container update resources %s: %w", id, err)
	}
	return append([]string(nil), resp.Warnings...), nil
}

// defaultMemorySwapLimit preserves Docker's default policy for a container
// with a memory limit: total memory+swap is twice the RAM limit. Supplying it
// explicitly on updates is important because Docker otherwise retains the
// old swap ceiling and can reject a RAM increase above that ceiling.
func defaultMemorySwapLimit(memoryBytes int64) (int64, error) {
	if memoryBytes == 0 {
		return 0, nil
	}
	if memoryBytes < 0 || memoryBytes > math.MaxInt64/2 {
		return 0, fmt.Errorf("memory limit %d cannot be represented with Docker's default swap allowance", memoryBytes)
	}
	return memoryBytes * 2, nil
}

// ImageInspect returns full image metadata (used by `list` to show
// per-box image version drift).
func (c *Client) ImageInspect(ctx context.Context, tag string) (image.InspectResponse, error) {
	resp, err := c.cli.ImageInspect(ctx, tag)
	if err != nil {
		return image.InspectResponse{}, fmt.Errorf("docker: image inspect %s: %w", tag, err)
	}
	return resp, nil
}

// ImageList returns image summaries matching a reference filter (e.g.
// "tx9-box:*"), used by `tx9 prune` to find stale box images.
func (c *Client) ImageList(ctx context.Context, referenceFilter string) ([]image.Summary, error) {
	f := filters.NewArgs(filters.Arg("reference", referenceFilter))
	images, err := c.cli.ImageList(ctx, image.ListOptions{Filters: f})
	if err != nil {
		return nil, fmt.Errorf("docker: list images %s: %w", referenceFilter, err)
	}
	return images, nil
}

// ImageRemove removes an image by ID or tag.
func (c *Client) ImageRemove(ctx context.Context, ref string) error {
	if _, err := c.cli.ImageRemove(ctx, ref, image.RemoveOptions{}); err != nil {
		return fmt.Errorf("docker: image remove %s: %w", ref, err)
	}
	return nil
}

// ExecResult is the outcome of a non-interactive Exec call.
type ExecResult struct {
	Stdout   string
	Stderr   string
	ExitCode int
}

// Exec runs cmd inside containerID (no TTY), waits for completion, and
// returns its combined stdout/stderr and exit code. This is the
// "remote-control" pattern used to invoke `hb` inside the agent container
// (dossier §3, `_guest_hb`) for calls like `up`/`doctor`/`wire-once`.
//
// Interactive/TTY exec (e.g. `tx9 enter`) needs raw terminal handling this
// helper doesn't provide and should use Raw() directly.
func (c *Client) Exec(ctx context.Context, containerID string, cmd []string, env []string, user string) (ExecResult, error) {
	created, err := c.cli.ContainerExecCreate(ctx, containerID, container.ExecOptions{
		Cmd:          cmd,
		Env:          env,
		User:         user,
		AttachStdout: true,
		AttachStderr: true,
	})
	if err != nil {
		return ExecResult{}, fmt.Errorf("docker: exec create: %w", err)
	}

	attach, err := c.cli.ContainerExecAttach(ctx, created.ID, container.ExecAttachOptions{})
	if err != nil {
		return ExecResult{}, fmt.Errorf("docker: exec attach: %w", err)
	}
	defer attach.Close()

	var stdout, stderr bytes.Buffer
	if _, err := stdcopy.StdCopy(&stdout, &stderr, attach.Reader); err != nil {
		return ExecResult{}, fmt.Errorf("docker: exec read output: %w", err)
	}

	inspect, err := c.cli.ContainerExecInspect(ctx, created.ID)
	if err != nil {
		return ExecResult{}, fmt.Errorf("docker: exec inspect: %w", err)
	}

	return ExecResult{
		Stdout:   stdout.String(),
		Stderr:   stderr.String(),
		ExitCode: inspect.ExitCode,
	}, nil
}
