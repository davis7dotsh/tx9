package box

import (
	"context"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/docker/go-units"

	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/state"
)

const (
	// Resource settings are stored in the box env file. CPU values use
	// Docker's NanoCPUs representation; memory and volume budgets are bytes.
	AgentNanoCPUsEnv             = "TX9_AGENT_NANO_CPUS"
	AgentMemoryBytesEnv          = "TX9_AGENT_MEMORY_BYTES"
	ExecutorNanoCPUsEnv          = "TX9_EXECUTOR_NANO_CPUS"
	ExecutorMemoryBytesEnv       = "TX9_EXECUTOR_MEMORY_BYTES"
	AgentVolumeBudgetBytesEnv    = "TX9_AGENT_VOLUME_BUDGET_BYTES"
	ExecutorVolumeBudgetBytesEnv = "TX9_EXECUTOR_VOLUME_BUDGET_BYTES"

	// Defaults preserve the limits from docker/compose.yaml: the agent gets
	// 4 CPUs and 8 GiB, while the executor gets 2 CPUs and 2 GiB.
	DefaultAgentNanoCPUs       int64 = 4_000_000_000
	DefaultAgentMemoryBytes    int64 = 8 * units.GiB
	DefaultExecutorNanoCPUs    int64 = 2_000_000_000
	DefaultExecutorMemoryBytes int64 = 2 * units.GiB
	MinimumMemoryBytes         int64 = 6 * units.MiB

	// Keep the original package-local names available to focused box tests
	// and code that describes the historical defaults.
	agentNanoCPUs       = DefaultAgentNanoCPUs
	agentMemoryBytes    = DefaultAgentMemoryBytes
	executorNanoCPUs    = DefaultExecutorNanoCPUs
	executorMemoryBytes = DefaultExecutorMemoryBytes
)

var resourceEnvKeys = []string{
	AgentNanoCPUsEnv,
	AgentMemoryBytesEnv,
	ExecutorNanoCPUsEnv,
	ExecutorMemoryBytesEnv,
	AgentVolumeBudgetBytesEnv,
	ExecutorVolumeBudgetBytesEnv,
}

// ContainerResources is the CPU and RAM allocation for one box container.
// NanoCPUs follows Docker's representation: one CPU is 1,000,000,000.
type ContainerResources struct {
	NanoCPUs    int64
	MemoryBytes int64
}

// Resources contains the allocations for both box containers and advisory
// budgets for their durable volumes. Docker named volumes do not provide a
// portable hard-quota API, so a volume budget of zero means unlimited and a
// non-zero value is reported as a usage warning rather than enforced.
type Resources struct {
	Agent                     ContainerResources
	Executor                  ContainerResources
	AgentVolumeBudgetBytes    int64
	ExecutorVolumeBudgetBytes int64
}

// DefaultResources returns the allocations used when no per-box settings
// have been persisted.
func DefaultResources() Resources {
	return Resources{
		Agent: ContainerResources{
			NanoCPUs:    DefaultAgentNanoCPUs,
			MemoryBytes: DefaultAgentMemoryBytes,
		},
		Executor: ContainerResources{
			NanoCPUs:    DefaultExecutorNanoCPUs,
			MemoryBytes: DefaultExecutorMemoryBytes,
		},
	}
}

// WithDefaults fills zero CPU/RAM fields with tx9's defaults. Volume budgets
// deliberately remain zero because zero means unlimited for those fields.
func (r Resources) WithDefaults() Resources {
	defaults := DefaultResources()
	if r.Agent.NanoCPUs == 0 {
		r.Agent.NanoCPUs = defaults.Agent.NanoCPUs
	}
	if r.Agent.MemoryBytes == 0 {
		r.Agent.MemoryBytes = defaults.Agent.MemoryBytes
	}
	if r.Executor.NanoCPUs == 0 {
		r.Executor.NanoCPUs = defaults.Executor.NanoCPUs
	}
	if r.Executor.MemoryBytes == 0 {
		r.Executor.MemoryBytes = defaults.Executor.MemoryBytes
	}
	return r
}

// Validate rejects allocations Docker cannot apply. CPU and RAM must be
// positive; only advisory volume budgets accept zero (unlimited).
func (r Resources) Validate() error {
	for _, allocation := range []struct {
		name      string
		resources ContainerResources
	}{
		{name: "agent", resources: r.Agent},
		{name: "executor", resources: r.Executor},
	} {
		if allocation.resources.NanoCPUs <= 0 {
			return fmt.Errorf("%s CPUs must be greater than zero", allocation.name)
		}
		if allocation.resources.MemoryBytes < MinimumMemoryBytes {
			return fmt.Errorf("%s memory must be at least %s", allocation.name, FormatBytes(MinimumMemoryBytes))
		}
		if allocation.resources.MemoryBytes > math.MaxInt64/2 {
			return fmt.Errorf("%s memory is too large to preserve Docker's default swap allowance", allocation.name)
		}
	}
	if r.AgentVolumeBudgetBytes < 0 {
		return fmt.Errorf("agent volume budget must be zero (unlimited) or greater")
	}
	if r.ExecutorVolumeBudgetBytes < 0 {
		return fmt.Errorf("executor volume budget must be zero (unlimited) or greater")
	}
	return nil
}

// LoadResources reads a box's persisted resource settings. Missing CPU/RAM
// keys receive tx9's defaults and missing volume budgets are unlimited.
func LoadResources(name string) (Resources, error) {
	env, err := state.ReadBoxEnv(name)
	if err != nil {
		return Resources{}, fmt.Errorf("box: load resources %s: %w", name, err)
	}

	resources := DefaultResources()
	fields := []struct {
		key       string
		dest      *int64
		allowZero bool
	}{
		{key: AgentNanoCPUsEnv, dest: &resources.Agent.NanoCPUs},
		{key: AgentMemoryBytesEnv, dest: &resources.Agent.MemoryBytes},
		{key: ExecutorNanoCPUsEnv, dest: &resources.Executor.NanoCPUs},
		{key: ExecutorMemoryBytesEnv, dest: &resources.Executor.MemoryBytes},
		{key: AgentVolumeBudgetBytesEnv, dest: &resources.AgentVolumeBudgetBytes, allowZero: true},
		{key: ExecutorVolumeBudgetBytesEnv, dest: &resources.ExecutorVolumeBudgetBytes, allowZero: true},
	}
	for _, field := range fields {
		raw, ok := env[field.key]
		if !ok {
			continue
		}
		value, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
		if err != nil || value < 0 || (!field.allowZero && value == 0) {
			return Resources{}, fmt.Errorf("box: load resources %s: invalid %s value %q", name, field.key, raw)
		}
		*field.dest = value
	}
	if err := resources.Validate(); err != nil {
		return Resources{}, fmt.Errorf("box: load resources %s: %w", name, err)
	}
	return resources, nil
}

// SaveResources persists a complete resource configuration without
// discarding token, executor, mount, or future settings in the box env file.
// Zero CPU/RAM fields are resolved to tx9's defaults for convenient use with
// a partially-populated Resources value.
func SaveResources(name string, resources Resources) error {
	resources = resources.WithDefaults()
	if err := resources.Validate(); err != nil {
		return fmt.Errorf("box: save resources %s: %w", name, err)
	}
	env, err := state.ReadBoxEnv(name)
	if err != nil {
		return fmt.Errorf("box: save resources %s: %w", name, err)
	}
	env[AgentNanoCPUsEnv] = strconv.FormatInt(resources.Agent.NanoCPUs, 10)
	env[AgentMemoryBytesEnv] = strconv.FormatInt(resources.Agent.MemoryBytes, 10)
	env[ExecutorNanoCPUsEnv] = strconv.FormatInt(resources.Executor.NanoCPUs, 10)
	env[ExecutorMemoryBytesEnv] = strconv.FormatInt(resources.Executor.MemoryBytes, 10)
	env[AgentVolumeBudgetBytesEnv] = strconv.FormatInt(resources.AgentVolumeBudgetBytes, 10)
	env[ExecutorVolumeBudgetBytesEnv] = strconv.FormatInt(resources.ExecutorVolumeBudgetBytes, 10)
	if err := state.WriteBoxEnv(name, env); err != nil {
		return fmt.Errorf("box: save resources %s: %w", name, err)
	}
	return nil
}

// ResetResources deletes only resource-related settings. The next load uses
// tx9's defaults, while unrelated settings remain untouched.
func ResetResources(name string) error {
	env, err := state.ReadBoxEnv(name)
	if err != nil {
		return fmt.Errorf("box: reset resources %s: %w", name, err)
	}
	for _, key := range resourceEnvKeys {
		delete(env, key)
	}
	if err := state.WriteBoxEnv(name, env); err != nil {
		return fmt.Errorf("box: reset resources %s: %w", name, err)
	}
	return nil
}

// InspectResources returns daemon-truth CPU/RAM limits for every container
// that exists and persisted desired values for a missing role, so a repair
// upgrade does not silently discard its allocation. Advisory volume budgets
// always come from persisted state. Inspection failures return the
// successfully-inspected partial result together with an error.
func InspectResources(ctx context.Context, cli *docker.Client, b *Box) (Resources, error) {
	stored, err := LoadResources(b.Name)
	if err != nil {
		return Resources{}, err
	}
	resources := stored

	var errs []error
	inspect := func(role, id string, dest *ContainerResources) {
		if id == "" {
			return
		}
		containerInfo, inspectErr := cli.ContainerInspect(ctx, id)
		if inspectErr != nil {
			errs = append(errs, fmt.Errorf("%s: %w", role, inspectErr))
			return
		}
		if containerInfo.HostConfig == nil {
			errs = append(errs, fmt.Errorf("%s: inspect response has no host config", role))
			return
		}
		dest.NanoCPUs = containerInfo.HostConfig.NanoCPUs
		dest.MemoryBytes = containerInfo.HostConfig.Memory
	}
	inspect("agent", b.AgentID, &resources.Agent)
	inspect("executor", b.ExecutorID, &resources.Executor)
	if len(errs) > 0 {
		return resources, fmt.Errorf("box: inspect resources %s: %w", b.Name, errors.Join(errs...))
	}
	return resources, nil
}

// ParseCPUs converts a human CPU count such as "4" or "1.5" into Docker's
// NanoCPUs representation.
func ParseCPUs(value string) (int64, error) {
	value = strings.TrimSpace(value)
	cpus, err := strconv.ParseFloat(value, 64)
	if err != nil || math.IsNaN(cpus) || math.IsInf(cpus, 0) || cpus <= 0 {
		return 0, fmt.Errorf("CPU count must be a number greater than zero: %q", value)
	}
	if cpus > float64(math.MaxInt64)/1_000_000_000 {
		return 0, fmt.Errorf("CPU count is too large: %q", value)
	}
	nanoCPUs := int64(math.Round(cpus * 1_000_000_000))
	if nanoCPUs == 0 {
		return 0, fmt.Errorf("CPU count is too small: %q", value)
	}
	return nanoCPUs, nil
}

// FormatCPUs formats Docker NanoCPUs without unnecessary trailing zeroes.
// Zero means Docker has no CPU limit.
func FormatCPUs(nanoCPUs int64) string {
	if nanoCPUs == 0 {
		return "unlimited"
	}
	return strconv.FormatFloat(float64(nanoCPUs)/1_000_000_000, 'f', -1, 64)
}

// ParseMemoryBytes parses a positive binary size accepted by Docker, such as
// "8GiB", "2048MiB", or a raw byte count.
func ParseMemoryBytes(value string) (int64, error) {
	bytes, err := ParseBytes(value)
	if err != nil || bytes < MinimumMemoryBytes {
		return 0, fmt.Errorf("memory must be at least %s: %q", FormatBytes(MinimumMemoryBytes), value)
	}
	return bytes, nil
}

// ParseBytes parses a non-negative binary size accepted by Docker. Callers
// that require a positive value or Docker's minimum memory allocation should
// additionally use Resources.Validate or ParseMemoryBytes.
func ParseBytes(value string) (int64, error) {
	bytes, err := units.RAMInBytes(strings.TrimSpace(value))
	if err != nil || bytes < 0 {
		return 0, fmt.Errorf("invalid byte size: %q", value)
	}
	return bytes, nil
}

// ParseVolumeBudgetBytes parses an advisory volume budget. "unlimited" and
// zero both disable the warning threshold.
func ParseVolumeBudgetBytes(value string) (int64, error) {
	value = strings.TrimSpace(value)
	if strings.EqualFold(value, "unlimited") || value == "0" {
		return 0, nil
	}
	bytes, err := ParseBytes(value)
	if err != nil || bytes <= 0 {
		return 0, fmt.Errorf("volume budget must be a size greater than zero or unlimited: %q", value)
	}
	return bytes, nil
}

// FormatBytes formats bytes with binary units (for example, 8GiB).
func FormatBytes(bytes int64) string {
	return units.BytesSize(float64(bytes))
}

// FormatVolumeBudget formats zero as "unlimited" and non-zero budgets with
// binary units.
func FormatVolumeBudget(bytes int64) string {
	if bytes == 0 {
		return "unlimited"
	}
	return FormatBytes(bytes)
}
