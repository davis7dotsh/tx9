package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
)

func showOverview(w io.Writer) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return withDockerContext(ctx, func(ctx context.Context, cli *docker.Client) error {
		boxes, err := box.List(ctx, cli)
		if err != nil {
			return fmt.Errorf("list boxes: %w", err)
		}

		volumeNames := make([]string, 0, len(boxes)*2)
		for _, b := range boxes {
			agentVolume, executorVolume := box.VolumeNames(b.Name)
			volumeNames = append(volumeNames, agentVolume, executorVolume)
		}
		usage := make(map[string]int64, len(volumeNames))
		for _, name := range volumeNames {
			usage[name] = -1
		}
		if len(volumeNames) > 0 {
			measured, warnings, usageErr := cli.VolumeUsage(ctx, volumeNames...)
			if usageErr != nil {
				fmt.Fprintf(os.Stderr, "tx9: warning: volume usage unavailable: %v\n", usageErr)
			} else {
				usage = measured
				printDockerWarnings(warnings)
			}
		}

		overview := make([]overviewBox, 0, len(boxes))
		for i := range boxes {
			b := &boxes[i]
			agentVolume, executorVolume := box.VolumeNames(b.Name)
			entry := overviewBox{
				Name:         b.Name,
				State:        b.DerivedState(),
				ImageVersion: imageVersionDisplay(b.Version),
				Agent: overviewContainer{
					Missing: b.AgentID == "",
				},
				Executor: overviewContainer{
					Missing: b.ExecutorID == "",
				},
				AgentVolume: overviewVolume{
					UsedBytes: usage[agentVolume],
				},
				ExecutorVolume: overviewVolume{
					UsedBytes: usage[executorVolume],
				},
			}

			if resources, loadErr := box.LoadResources(b.Name); loadErr == nil {
				entry.AgentVolume.BudgetBytes = resources.AgentVolumeBudgetBytes
				entry.ExecutorVolume.BudgetBytes = resources.ExecutorVolumeBudgetBytes
				entry.AgentVolume.BudgetKnown = true
				entry.ExecutorVolume.BudgetKnown = true
			} else {
				fmt.Fprintf(os.Stderr, "tx9: warning: %s resource settings unavailable: %v\n", b.Name, loadErr)
			}
			populateOverviewContainer(ctx, cli, b.Name, "agent", b.AgentID, &entry.Agent)
			populateOverviewContainer(ctx, cli, b.Name, "executor", b.ExecutorID, &entry.Executor)

			if entry.State == "running" {
				if port, portErr := box.HostPort(ctx, cli, b); portErr == nil {
					entry.DashboardURL = box.DashboardURL(port, b.ExecutorWebBaseURL)
				}
			}
			overview = append(overview, entry)
		}

		renderOverview(w, overview)
		return nil
	})
}

func populateOverviewContainer(ctx context.Context, cli *docker.Client, boxName, role, id string, target *overviewContainer) {
	if id == "" {
		return
	}
	info, err := cli.ContainerInspect(ctx, id)
	if err != nil {
		fmt.Fprintf(os.Stderr, "tx9: warning: inspect %s %s: %v\n", boxName, role, err)
		return
	}
	if info.HostConfig == nil {
		fmt.Fprintf(os.Stderr, "tx9: warning: inspect %s %s: Docker returned no host config\n", boxName, role)
		return
	}
	target.CPUs = float64(info.HostConfig.NanoCPUs) / 1_000_000_000
	target.MemoryBytes = info.HostConfig.Memory
	target.Inspected = true
}
