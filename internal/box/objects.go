package box

import (
	"context"
	"fmt"

	dockernetwork "github.com/docker/docker/api/types/network"
	dockerclient "github.com/docker/docker/client"

	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/names"
)

// PreflightFreshObjects rejects names whose containers have been removed but
// whose durable volumes or network remain. Fresh create/import must call this
// under the box lock, before writing a new token or changing Docker objects.
// Upgrade intentionally reuses owned objects through ensureNetwork/Volume.
func PreflightFreshObjects(ctx context.Context, cli *docker.Client, name string) error {
	if err := names.Validate(name); err != nil {
		return err
	}
	agent, executor := ContainerNames(name)
	for _, container := range []string{agent, executor} {
		if _, err := cli.ContainerInspect(ctx, container); err == nil {
			return existingObjectError(name, "container", container)
		} else if !dockerclient.IsErrNotFound(err) {
			return err
		}
	}
	network := NetworkName(name)
	if _, err := cli.Raw().NetworkInspect(ctx, network, dockernetwork.InspectOptions{}); err == nil {
		return existingObjectError(name, "network", network)
	} else if !dockerclient.IsErrNotFound(err) {
		return fmt.Errorf("inspect network %s: %w", network, err)
	}
	agentVolume, executorVolume := VolumeNames(name)
	for _, volume := range []string{agentVolume, executorVolume} {
		if _, err := cli.Raw().VolumeInspect(ctx, volume); err == nil {
			return existingObjectError(name, "volume", volume)
		} else if !dockerclient.IsErrNotFound(err) {
			return fmt.Errorf("inspect volume %s: %w", volume, err)
		}
	}
	return nil
}

func existingObjectError(box, kind, name string) error {
	return fmt.Errorf("box %q already has Docker %s %q; choose a different box name or recover/remove the existing resources explicitly", box, kind, name)
}

// PreflightExistingObjects checks ownership before upgrade removes containers.
// Missing objects remain recreatable, but a name collision must not leave the
// existing box stopped before Create discovers the conflicting labels.
func PreflightExistingObjects(ctx context.Context, cli *docker.Client, name string) error {
	if err := names.Validate(name); err != nil {
		return err
	}
	network := NetworkName(name)
	inspect, err := cli.Raw().NetworkInspect(ctx, network, dockernetwork.InspectOptions{})
	if err == nil && !ownedByBox(inspect.Labels, name) {
		return fmt.Errorf("refusing to reuse network %s: it is not owned by box %s", network, name)
	}
	if err != nil && !dockerclient.IsErrNotFound(err) {
		return fmt.Errorf("inspect network %s: %w", network, err)
	}
	agentVolume, executorVolume := VolumeNames(name)
	for _, volume := range []string{agentVolume, executorVolume} {
		inspect, err := cli.Raw().VolumeInspect(ctx, volume)
		if err == nil && !ownedByBox(inspect.Labels, name) {
			return fmt.Errorf("refusing to reuse volume %s: it is not owned by box %s", volume, name)
		}
		if err != nil && !dockerclient.IsErrNotFound(err) {
			return fmt.Errorf("inspect volume %s: %w", volume, err)
		}
	}
	return nil
}

func ownedByBox(labels map[string]string, name string) bool {
	return labels[docker.LabelManaged] == "1" && labels[docker.LabelBox] == name
}

func removeOwnedContainer(ctx context.Context, cli *docker.Client, id, name string) error {
	inspect, err := cli.ContainerInspect(ctx, id)
	if dockerclient.IsErrNotFound(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if inspect.Config == nil || !ownedByBox(inspect.Config.Labels, name) {
		return fmt.Errorf("refusing to remove container %s: it is not owned by box %s", id, name)
	}
	if err := cli.ContainerRemove(ctx, inspect.ID, true); err != nil && !dockerclient.IsErrNotFound(err) {
		return err
	}
	return nil
}

func removeOwnedNetwork(ctx context.Context, cli *docker.Client, network, name string) error {
	inspect, err := cli.Raw().NetworkInspect(ctx, network, dockernetwork.InspectOptions{})
	if dockerclient.IsErrNotFound(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect network %s: %w", network, err)
	}
	if !ownedByBox(inspect.Labels, name) {
		return fmt.Errorf("refusing to remove network %s: it is not owned by box %s", network, name)
	}
	if err := cli.NetworkRemove(ctx, inspect.ID); err != nil && !dockerclient.IsErrNotFound(err) {
		return err
	}
	return nil
}

func removeOwnedVolume(ctx context.Context, cli *docker.Client, volume, name string) error {
	inspect, err := cli.Raw().VolumeInspect(ctx, volume)
	if dockerclient.IsErrNotFound(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect volume %s: %w", volume, err)
	}
	if !ownedByBox(inspect.Labels, name) {
		return fmt.Errorf("refusing to remove volume %s: it is not owned by box %s", volume, name)
	}
	if err := cli.VolumeRemove(ctx, volume, true); err != nil && !dockerclient.IsErrNotFound(err) {
		return err
	}
	return nil
}
