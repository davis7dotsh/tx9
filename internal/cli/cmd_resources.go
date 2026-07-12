package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
)

type resourceFlagValues struct {
	agentCPUs            string
	agentMemory          string
	executorCPUs         string
	executorMemory       string
	agentVolumeBudget    string
	executorVolumeBudget string
}

type containerResourceUpdater interface {
	ContainerUpdateResources(context.Context, string, int64, int64) ([]string, error)
}

func addResourceConfigFlags(fs *flag.FlagSet) *resourceFlagValues {
	values := &resourceFlagValues{}
	fs.StringVar(&values.agentCPUs, "agent-cpus", "", "agent CPU limit (for example 4 or 6.5)")
	fs.StringVar(&values.agentMemory, "agent-memory", "", "agent memory limit (for example 8GiB)")
	fs.StringVar(&values.executorCPUs, "executor-cpus", "", "Executor CPU limit")
	fs.StringVar(&values.executorMemory, "executor-memory", "", "Executor memory limit")
	fs.StringVar(&values.agentVolumeBudget, "agent-volume-budget", "", "advisory agent volume budget, or unlimited")
	fs.StringVar(&values.executorVolumeBudget, "executor-volume-budget", "", "advisory Executor volume budget, or unlimited")
	return values
}

func (f *resourceFlagValues) hasOverrides() bool {
	return f.agentCPUs != "" || f.agentMemory != "" ||
		f.executorCPUs != "" || f.executorMemory != "" ||
		f.agentVolumeBudget != "" || f.executorVolumeBudget != ""
}

func (f *resourceFlagValues) apply(base box.Resources) (box.Resources, error) {
	result := base.WithDefaults()
	var err error
	if f.agentCPUs != "" {
		result.Agent.NanoCPUs, err = box.ParseCPUs(f.agentCPUs)
		if err != nil {
			return box.Resources{}, fmt.Errorf("--agent-cpus: %w", err)
		}
	}
	if f.agentMemory != "" {
		result.Agent.MemoryBytes, err = box.ParseMemoryBytes(f.agentMemory)
		if err != nil {
			return box.Resources{}, fmt.Errorf("--agent-memory: %w", err)
		}
	}
	if f.executorCPUs != "" {
		result.Executor.NanoCPUs, err = box.ParseCPUs(f.executorCPUs)
		if err != nil {
			return box.Resources{}, fmt.Errorf("--executor-cpus: %w", err)
		}
	}
	if f.executorMemory != "" {
		result.Executor.MemoryBytes, err = box.ParseMemoryBytes(f.executorMemory)
		if err != nil {
			return box.Resources{}, fmt.Errorf("--executor-memory: %w", err)
		}
	}
	if f.agentVolumeBudget != "" {
		result.AgentVolumeBudgetBytes, err = box.ParseVolumeBudgetBytes(f.agentVolumeBudget)
		if err != nil {
			return box.Resources{}, fmt.Errorf("--agent-volume-budget: %w", err)
		}
	}
	if f.executorVolumeBudget != "" {
		result.ExecutorVolumeBudgetBytes, err = box.ParseVolumeBudgetBytes(f.executorVolumeBudget)
		if err != nil {
			return box.Resources{}, fmt.Errorf("--executor-volume-budget: %w", err)
		}
	}
	if err := result.Validate(); err != nil {
		return box.Resources{}, err
	}
	return result, nil
}

func cmdResources(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("resources: box name required (usage: tx9 resources <box>)")
	}
	action, args := splitResourcesAction(args)
	switch action {
	case "show":
		return cmdResourcesShow(args)
	case "set":
		return cmdResourcesSet(args)
	case "reset":
		return cmdResourcesReset(args)
	default:
		panic("unreachable")
	}
}

func splitResourcesAction(args []string) (string, []string) {
	// show/set/reset were all valid box names before `resources` existed. A
	// lone action-looking word therefore remains a box name; repeat it to act
	// on such a box (for example, `tx9 resources reset reset`).
	if len(args) > 1 && (args[0] == "show" || args[0] == "set" || args[0] == "reset") {
		return args[0], args[1:]
	}
	return "show", args
}

func cmdResourcesShow(args []string) error {
	fs := flag.NewFlagSet("resources", flag.ContinueOnError)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	name, err := requireBoxName(fs, "resources")
	if err != nil {
		return err
	}

	return withDocker(func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("resources %s: %w", name, err)
		}
		resources, err := box.InspectResources(ctx, cli, b)
		if err != nil {
			return fmt.Errorf("resources %s: %w", name, err)
		}
		agentVolume, executorVolume := box.VolumeNames(name)
		agentUsed, executorUsed := int64(-1), int64(-1)
		usage, warnings, usageErr := cli.VolumeUsage(ctx, agentVolume, executorVolume)
		if usageErr != nil {
			fmt.Fprintf(os.Stderr, "tx9: warning: volume usage unavailable: %v\n", usageErr)
		} else {
			printDockerWarnings(warnings)
			agentUsed = usage[agentVolume]
			executorUsed = usage[executorVolume]
		}
		printResources(name, b, resources, agentUsed, executorUsed)
		return nil
	})
}

func cmdResourcesSet(args []string) error {
	fs := flag.NewFlagSet("resources set", flag.ContinueOnError)
	flags := addResourceConfigFlags(fs)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	name, err := requireBoxName(fs, "resources set")
	if err != nil {
		return err
	}
	if !flags.hasOverrides() {
		return fmt.Errorf("resources set %s: at least one resource flag is required", name)
	}

	return withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("resources set %s: %w", name, err)
		}
		oldResources, err := requireCompleteResources(ctx, cli, b)
		if err != nil {
			return fmt.Errorf("resources set %s: %w", name, err)
		}
		newResources, err := flags.apply(oldResources)
		if err != nil {
			return fmt.Errorf("resources set %s: %w", name, err)
		}
		if err := applyResourcesTransaction(ctx, cli, b, oldResources, newResources, func() error {
			return box.SaveResources(name, newResources)
		}); err != nil {
			return fmt.Errorf("resources set %s: %w", name, err)
		}
		fmt.Printf("tx9: resources updated for %s\n", name)
		return nil
	})
}

func cmdResourcesReset(args []string) error {
	fs := flag.NewFlagSet("resources reset", flag.ContinueOnError)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	name, err := requireBoxName(fs, "resources reset")
	if err != nil {
		return err
	}

	return withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("resources reset %s: %w", name, err)
		}
		oldResources, err := requireCompleteResources(ctx, cli, b)
		if err != nil {
			return fmt.Errorf("resources reset %s: %w", name, err)
		}
		defaults := box.DefaultResources()
		if err := applyResourcesTransaction(ctx, cli, b, oldResources, defaults, func() error {
			return box.ResetResources(name)
		}); err != nil {
			return fmt.Errorf("resources reset %s: %w", name, err)
		}
		fmt.Printf("tx9: resources reset to defaults for %s\n", name)
		return nil
	})
}

func requireCompleteResources(ctx context.Context, cli *docker.Client, b *box.Box) (box.Resources, error) {
	if b.AgentID == "" || b.ExecutorID == "" {
		return box.Resources{}, fmt.Errorf("both containers are required (agent=%t executor=%t); run `tx9 upgrade %s` to repair the box", b.AgentID != "", b.ExecutorID != "", b.Name)
	}
	resources, err := box.InspectResources(ctx, cli, b)
	if err != nil {
		return box.Resources{}, err
	}
	if resources.Agent.NanoCPUs <= 0 || resources.Agent.MemoryBytes <= 0 ||
		resources.Executor.NanoCPUs <= 0 || resources.Executor.MemoryBytes <= 0 {
		return box.Resources{}, fmt.Errorf("container inspection returned incomplete CPU/RAM limits")
	}
	return resources, nil
}

func applyResourcesTransaction(ctx context.Context, cli containerResourceUpdater, b *box.Box, oldResources, newResources box.Resources, persist func() error) error {
	var updatedAgent, updatedExecutor bool
	if oldResources.Agent != newResources.Agent {
		warnings, err := cli.ContainerUpdateResources(ctx, b.AgentID, newResources.Agent.NanoCPUs, newResources.Agent.MemoryBytes)
		printDockerWarnings(warnings)
		if err != nil {
			return fmt.Errorf("update agent: %w", err)
		}
		updatedAgent = true
	}
	if oldResources.Executor != newResources.Executor {
		warnings, err := cli.ContainerUpdateResources(ctx, b.ExecutorID, newResources.Executor.NanoCPUs, newResources.Executor.MemoryBytes)
		printDockerWarnings(warnings)
		if err != nil {
			var rollbackErr error
			if updatedAgent {
				_, rollbackErr = cli.ContainerUpdateResources(ctx, b.AgentID, oldResources.Agent.NanoCPUs, oldResources.Agent.MemoryBytes)
			}
			return errors.Join(fmt.Errorf("update executor: %w", err), wrapRollbackError("agent", rollbackErr))
		}
		updatedExecutor = true
	}

	if err := persist(); err != nil {
		var rollbackErrs []error
		if updatedExecutor {
			if _, rollbackErr := cli.ContainerUpdateResources(ctx, b.ExecutorID, oldResources.Executor.NanoCPUs, oldResources.Executor.MemoryBytes); rollbackErr != nil {
				rollbackErrs = append(rollbackErrs, fmt.Errorf("rollback executor: %w", rollbackErr))
			}
		}
		if updatedAgent {
			if _, rollbackErr := cli.ContainerUpdateResources(ctx, b.AgentID, oldResources.Agent.NanoCPUs, oldResources.Agent.MemoryBytes); rollbackErr != nil {
				rollbackErrs = append(rollbackErrs, fmt.Errorf("rollback agent: %w", rollbackErr))
			}
		}
		return errors.Join(fmt.Errorf("persist resource settings: %w", err), errors.Join(rollbackErrs...))
	}
	return nil
}

func wrapRollbackError(role string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("rollback %s: %w", role, err)
}

func printDockerWarnings(warnings []string) {
	for _, warning := range warnings {
		fmt.Fprintf(os.Stderr, "tx9: warning: %s\n", warning)
	}
}

func printResources(name string, b *box.Box, resources box.Resources, agentUsed, executorUsed int64) {
	fmt.Printf("Box %s (%s)\n\n", name, b.DerivedState())
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "CONTAINER\tSTATE\tCPU LIMIT\tMEMORY LIMIT")
	fmt.Fprintf(w, "agent\t%s\t%s\t%s\n", resourceRoleState(b.AgentID, b.AgentState), formatResourceCPUs(b.AgentID, resources.Agent.NanoCPUs), formatResourceMemory(b.AgentID, resources.Agent.MemoryBytes))
	fmt.Fprintf(w, "executor\t%s\t%s\t%s\n", resourceRoleState(b.ExecutorID, b.ExecutorState), formatResourceCPUs(b.ExecutorID, resources.Executor.NanoCPUs), formatResourceMemory(b.ExecutorID, resources.Executor.MemoryBytes))
	fmt.Fprintln(w, "\nVOLUME\tUSED\tADVISORY BUDGET\tSTATUS")
	fmt.Fprintf(w, "agent-data\t%s\t%s\t%s\n", formatVolumeUsed(agentUsed), box.FormatVolumeBudget(resources.AgentVolumeBudgetBytes), volumeBudgetStatus(agentUsed, resources.AgentVolumeBudgetBytes))
	fmt.Fprintf(w, "exec-data\t%s\t%s\t%s\n", formatVolumeUsed(executorUsed), box.FormatVolumeBudget(resources.ExecutorVolumeBudgetBytes), volumeBudgetStatus(executorUsed, resources.ExecutorVolumeBudgetBytes))
	_ = w.Flush()
	fmt.Println("\nVolume budgets are warnings only; Docker local volumes remain host-backed and unbounded.")
}

func resourceRoleState(id, state string) string {
	if id == "" {
		return "missing"
	}
	if state == "" {
		return "unknown"
	}
	return state
}

func formatResourceBytes(bytes int64) string {
	if bytes <= 0 {
		return "unlimited"
	}
	return box.FormatBytes(bytes)
}

func formatResourceCPUs(id string, nanoCPUs int64) string {
	if id == "" {
		return "-"
	}
	return box.FormatCPUs(nanoCPUs)
}

func formatResourceMemory(id string, bytes int64) string {
	if id == "" {
		return "-"
	}
	return formatResourceBytes(bytes)
}

func formatVolumeUsed(bytes int64) string {
	if bytes < 0 {
		return "unknown"
	}
	return box.FormatBytes(bytes)
}

func volumeBudgetStatus(used, budget int64) string {
	if budget == 0 || used < 0 {
		return "-"
	}
	if used > budget {
		return "OVER"
	}
	return "ok"
}
