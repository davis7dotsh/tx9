package cli

import (
	"context"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/docker/docker/api/types/container"

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

		overview, warnings := collectOverview(ctx, cli, boxes)
		printDockerWarnings(warnings)
		renderOverview(w, overview)
		return nil
	})
}

type overviewClient interface {
	ContainerInspect(context.Context, string) (container.InspectResponse, error)
	VolumeUsage(context.Context, ...string) (map[string]int64, []string, error)
}

// Disk usage can take most of the overview's deadline on a large host. Run
// it alongside bounded container inspection so it cannot starve CPU/RAM
// and dashboard metadata. Each executor is inspected only once.
func collectOverview(ctx context.Context, cli overviewClient, boxes []box.Box) ([]overviewBox, []string) {
	entries := make([]overviewBox, len(boxes))
	if len(boxes) == 0 {
		return entries, nil
	}
	volumeNames := make([]string, 0, len(boxes)*2)
	for _, b := range boxes {
		a, e := box.VolumeNames(b.Name)
		volumeNames = append(volumeNames, a, e)
	}
	var usage map[string]int64
	var volumeWarnings []string
	var wg sync.WaitGroup
	wg.Go(func() {
		var err error
		usage, volumeWarnings, err = cli.VolumeUsage(ctx, volumeNames...)
		if err != nil {
			volumeWarnings = append(volumeWarnings, fmt.Sprintf("volume usage unavailable: %v", err))
		}
	})
	warnings := make([][]string, len(boxes))
	jobs := make(chan int)
	for range min(4, len(boxes)) {
		wg.Go(func() {
			for i := range jobs {
				entries[i], warnings[i] = collectOverviewBox(ctx, cli, &boxes[i])
			}
		})
	}
	for i := range boxes {
		jobs <- i
	}
	close(jobs)
	wg.Wait()

	var allWarnings []string
	for i := range entries {
		a, e := box.VolumeNames(boxes[i].Name)
		if used, ok := usage[a]; ok {
			entries[i].AgentVolume.UsedBytes = used
		}
		if used, ok := usage[e]; ok {
			entries[i].ExecutorVolume.UsedBytes = used
		}
		allWarnings = append(allWarnings, warnings[i]...)
	}
	return entries, append(allWarnings, volumeWarnings...)
}

func collectOverviewBox(ctx context.Context, cli overviewClient, b *box.Box) (overviewBox, []string) {
	entry := overviewBox{
		Name: b.Name, State: b.DerivedState(), ImageVersion: imageVersionDisplay(b.Version),
		Agent: overviewContainer{Missing: b.AgentID == ""}, Executor: overviewContainer{Missing: b.ExecutorID == ""},
		AgentVolume: overviewVolume{UsedBytes: -1}, ExecutorVolume: overviewVolume{UsedBytes: -1},
	}
	var warnings []string
	if resources, err := box.LoadResources(b.Name); err == nil {
		entry.AgentVolume.BudgetBytes = resources.AgentVolumeBudgetBytes
		entry.ExecutorVolume.BudgetBytes = resources.ExecutorVolumeBudgetBytes
		entry.AgentVolume.BudgetKnown = true
		entry.ExecutorVolume.BudgetKnown = true
	} else {
		warnings = append(warnings, fmt.Sprintf("%s resource settings unavailable: %v", b.Name, err))
	}
	if _, err := populateOverviewContainer(ctx, cli, b.AgentID, &entry.Agent); err != nil {
		warnings = append(warnings, fmt.Sprintf("inspect %s agent: %v", b.Name, err))
	}
	info, err := populateOverviewContainer(ctx, cli, b.ExecutorID, &entry.Executor)
	if err != nil {
		warnings = append(warnings, fmt.Sprintf("inspect %s executor: %v", b.Name, err))
	}
	if entry.State == "running" && info.NetworkSettings != nil {
		if bindings := info.NetworkSettings.Ports["4788/tcp"]; len(bindings) > 0 {
			entry.DashboardURL = box.DashboardURL(bindings[0].HostPort, b.ExecutorWebBaseURL)
		}
	}
	return entry, warnings
}

func populateOverviewContainer(ctx context.Context, cli overviewClient, id string, target *overviewContainer) (container.InspectResponse, error) {
	if id == "" {
		return container.InspectResponse{}, nil
	}
	info, err := cli.ContainerInspect(ctx, id)
	if err != nil {
		return info, err
	}
	if info.ContainerJSONBase == nil || info.HostConfig == nil {
		return info, fmt.Errorf("Docker returned no host config")
	}
	target.CPUs = float64(info.HostConfig.NanoCPUs) / 1_000_000_000
	target.MemoryBytes = info.HostConfig.Memory
	target.Inspected = true
	return info, nil
}
