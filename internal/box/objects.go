package box

import (
	"context"
	"errors"
	"fmt"

	dockernetwork "github.com/docker/docker/api/types/network"
	dockerclient "github.com/docker/docker/client"

	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/names"
)

// ErrObjectsExist identifies a fresh box name that collides with Docker objects.
var ErrObjectsExist = errors.New("box objects already exist")

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
	return fmt.Errorf("box %q already has Docker %s %q; choose a different box name or recover/remove the existing resources explicitly: %w", box, kind, name, ErrObjectsExist)
}

// PreflightExistingObjects checks ownership before upgrade removes containers.
// Missing objects remain recreatable, but a name collision must not leave the
// existing box stopped before Create discovers the conflicting labels.
func PreflightExistingObjects(ctx context.Context, cli *docker.Client, name string) error {
	if err := names.Validate(name); err != nil {
		return err
	}
	agent, executor := ContainerNames(name)
	for _, ref := range []string{agent, executor} {
		if _, err := inspectOwnedContainer(ctx, cli, ref, name); err != nil {
			return err
		}
	}
	if _, err := inspectOwnedNetwork(ctx, cli, NetworkName(name), name); err != nil {
		return err
	}
	agentVolume, executorVolume := VolumeNames(name)
	for _, volume := range []string{agentVolume, executorVolume} {
		if _, err := inspectOwnedVolume(ctx, cli, volume, name); err != nil {
			return err
		}
	}
	return nil
}

func ownedByBox(labels map[string]string, name string) bool {
	return labels[docker.LabelManaged] == "1" && labels[docker.LabelBox] == name
}

type destroyTargets struct {
	containerIDs []string
	networkID    string
	volumes      []string
}

// Inspect every deletion target before allowing any mutation. Derived names
// are checked even when labels find a container, so a foreign sibling cannot
// be missed in a partially created box. Labels also find renamed containers.
func inspectDestroyTargets(ctx context.Context, cli *docker.Client, name string) (destroyTargets, error) {
	if err := names.Validate(name); err != nil {
		return destroyTargets{}, err
	}
	agent, executor := ContainerNames(name)
	containerRefs := []string{agent, executor}
	containers, err := cli.ListBoxContainers(ctx)
	if err != nil {
		return destroyTargets{}, err
	}
	for _, container := range containers {
		if ownedByBox(container.Labels, name) {
			containerRefs = append(containerRefs, container.ID)
		}
	}
	var targets destroyTargets
	seen := make(map[string]bool)
	for _, ref := range containerRefs {
		if ref == "" || seen[ref] {
			continue
		}
		id, err := inspectOwnedContainer(ctx, cli, ref, name)
		if err != nil {
			return destroyTargets{}, err
		}
		if id != "" && !seen[id] {
			targets.containerIDs = append(targets.containerIDs, id)
			seen[id] = true
		}
	}
	targets.networkID, err = inspectOwnedNetwork(ctx, cli, NetworkName(name), name)
	if err != nil {
		return destroyTargets{}, err
	}
	agentVolume, executorVolume := VolumeNames(name)
	for _, ref := range []string{agentVolume, executorVolume} {
		volume, err := inspectOwnedVolume(ctx, cli, ref, name)
		if err != nil {
			return destroyTargets{}, err
		}
		if volume != "" {
			targets.volumes = append(targets.volumes, volume)
		}
	}
	return targets, nil
}

func inspectOwnedContainer(ctx context.Context, cli *docker.Client, id, name string) (string, error) {
	inspect, err := cli.ContainerInspect(ctx, id)
	if dockerclient.IsErrNotFound(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if inspect.Config == nil || !ownedByBox(inspect.Config.Labels, name) {
		return "", fmt.Errorf("refusing to use container %s: it is not owned by box %s", id, name)
	}
	if inspect.ContainerJSONBase == nil || inspect.ID == "" {
		return "", fmt.Errorf("inspect container %s: missing container ID", id)
	}
	return inspect.ID, nil
}

func inspectOwnedNetwork(ctx context.Context, cli *docker.Client, network, name string) (string, error) {
	inspect, err := cli.Raw().NetworkInspect(ctx, network, dockernetwork.InspectOptions{})
	if dockerclient.IsErrNotFound(err) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("inspect network %s: %w", network, err)
	}
	if !ownedByBox(inspect.Labels, name) {
		return "", fmt.Errorf("refusing to use network %s: it is not owned by box %s", network, name)
	}
	if inspect.ID == "" {
		return "", fmt.Errorf("inspect network %s: missing network ID", network)
	}
	return inspect.ID, nil
}

func inspectOwnedVolume(ctx context.Context, cli *docker.Client, volume, name string) (string, error) {
	inspect, err := cli.Raw().VolumeInspect(ctx, volume)
	if dockerclient.IsErrNotFound(err) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("inspect volume %s: %w", volume, err)
	}
	if !ownedByBox(inspect.Labels, name) {
		return "", fmt.Errorf("refusing to use volume %s: it is not owned by box %s", volume, name)
	}
	return volume, nil
}
