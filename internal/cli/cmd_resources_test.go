package cli

import (
	"context"
	"errors"
	"flag"
	"reflect"
	"strings"
	"testing"

	"github.com/davis7dotsh/tx9/internal/box"
)

type resourceUpdateCall struct {
	id          string
	nanoCPUs    int64
	memoryBytes int64
}

type fakeResourceUpdater struct {
	calls  []resourceUpdateCall
	failAt int
}

func (f *fakeResourceUpdater) ContainerUpdateResources(_ context.Context, id string, nanoCPUs, memoryBytes int64) ([]string, error) {
	f.calls = append(f.calls, resourceUpdateCall{id: id, nanoCPUs: nanoCPUs, memoryBytes: memoryBytes})
	if len(f.calls) == f.failAt {
		return nil, errors.New("update failed")
	}
	return nil, nil
}

func TestResourceFlagsApplyOverDefaults(t *testing.T) {
	fs := flag.NewFlagSet("resources", flag.ContinueOnError)
	flags := addResourceConfigFlags(fs)
	if err := fs.Parse([]string{
		"--agent-cpus", "6.5",
		"--agent-memory", "12GiB",
		"--executor-cpus", "3",
		"--executor-memory", "4GiB",
		"--agent-volume-budget", "96GiB",
		"--executor-volume-budget", "unlimited",
	}); err != nil {
		t.Fatal(err)
	}
	got, err := flags.apply(box.DefaultResources())
	if err != nil {
		t.Fatal(err)
	}
	if got.Agent.NanoCPUs != 6_500_000_000 || got.Agent.MemoryBytes != 12<<30 {
		t.Errorf("agent resources = %+v", got.Agent)
	}
	if got.Executor.NanoCPUs != 3_000_000_000 || got.Executor.MemoryBytes != 4<<30 {
		t.Errorf("executor resources = %+v", got.Executor)
	}
	if got.AgentVolumeBudgetBytes != 96<<30 || got.ExecutorVolumeBudgetBytes != 0 {
		t.Errorf("volume budgets = %d/%d", got.AgentVolumeBudgetBytes, got.ExecutorVolumeBudgetBytes)
	}
}

func TestResourceFlagsPreserveUnlimitedBaseValues(t *testing.T) {
	base := box.Resources{}
	fs := flag.NewFlagSet("resources", flag.ContinueOnError)
	flags := addResourceConfigFlags(fs)
	if err := fs.Parse([]string{"--agent-volume-budget", "10GiB"}); err != nil {
		t.Fatal(err)
	}

	got, err := flags.apply(base)
	if err != nil {
		t.Fatal(err)
	}
	if got.Agent != base.Agent || got.Executor != base.Executor {
		t.Fatalf("container allocations = %#v/%#v, want unlimited values preserved", got.Agent, got.Executor)
	}
	if got.AgentVolumeBudgetBytes != 10<<30 {
		t.Fatalf("agent volume budget = %d, want %d", got.AgentVolumeBudgetBytes, int64(10<<30))
	}
}

func TestSplitResourcesActionPreservesActionNamedBoxes(t *testing.T) {
	for _, name := range []string{"show", "set", "reset"} {
		action, args := splitResourcesAction([]string{name})
		if action != "show" || !reflect.DeepEqual(args, []string{name}) {
			t.Fatalf("split lone %s = %q/%#v, want show action for box", name, action, args)
		}
		action, args = splitResourcesAction([]string{name, name})
		if action != name || !reflect.DeepEqual(args, []string{name}) {
			t.Fatalf("split explicit %s = %q/%#v", name, action, args)
		}
	}
}

func TestVolumeBudgetStatus(t *testing.T) {
	cases := []struct {
		used, budget int64
		want         string
	}{
		{used: 1, budget: 0, want: "-"},
		{used: -1, budget: 10, want: "-"},
		{used: 9, budget: 10, want: "ok"},
		{used: 11, budget: 10, want: "OVER"},
	}
	for _, tc := range cases {
		if got := volumeBudgetStatus(tc.used, tc.budget); got != tc.want {
			t.Errorf("volumeBudgetStatus(%d, %d) = %q, want %q", tc.used, tc.budget, got, tc.want)
		}
	}
}

func TestMissingResourceRoleDoesNotRenderAsUnlimited(t *testing.T) {
	if got := formatResourceCPUs("", 0); got != "-" {
		t.Fatalf("missing CPU allocation = %q, want -", got)
	}
	if got := formatResourceMemory("", 0); got != "-" {
		t.Fatalf("missing memory allocation = %q, want -", got)
	}
}

func TestApplyResourcesTransactionRollsBackAgentWhenExecutorUpdateFails(t *testing.T) {
	oldResources := box.DefaultResources()
	newResources := oldResources
	newResources.Agent.NanoCPUs++
	newResources.Executor.NanoCPUs++
	updater := &fakeResourceUpdater{failAt: 2}
	persisted := false

	err := applyResourcesTransaction(context.Background(), updater, &box.Box{AgentID: "agent", ExecutorID: "executor"}, oldResources, newResources, func() error {
		persisted = true
		return nil
	})
	if err == nil || persisted {
		t.Fatalf("transaction error/persisted = %v/%t, want error/false", err, persisted)
	}
	want := []resourceUpdateCall{
		{id: "agent", nanoCPUs: newResources.Agent.NanoCPUs, memoryBytes: newResources.Agent.MemoryBytes},
		{id: "executor", nanoCPUs: newResources.Executor.NanoCPUs, memoryBytes: newResources.Executor.MemoryBytes},
		{id: "agent", nanoCPUs: oldResources.Agent.NanoCPUs, memoryBytes: oldResources.Agent.MemoryBytes},
	}
	if !reflect.DeepEqual(updater.calls, want) {
		t.Fatalf("update calls = %#v, want %#v", updater.calls, want)
	}
}

func TestApplyResourcesTransactionRollsBackBothWhenPersistenceFails(t *testing.T) {
	oldResources := box.DefaultResources()
	newResources := oldResources
	newResources.Agent.MemoryBytes++
	newResources.Executor.MemoryBytes++
	updater := &fakeResourceUpdater{}

	err := applyResourcesTransaction(context.Background(), updater, &box.Box{AgentID: "agent", ExecutorID: "executor"}, oldResources, newResources, func() error {
		return errors.New("persist failed")
	})
	if err == nil {
		t.Fatal("transaction error = nil")
	}
	want := []resourceUpdateCall{
		{id: "agent", nanoCPUs: newResources.Agent.NanoCPUs, memoryBytes: newResources.Agent.MemoryBytes},
		{id: "executor", nanoCPUs: newResources.Executor.NanoCPUs, memoryBytes: newResources.Executor.MemoryBytes},
		{id: "executor", nanoCPUs: oldResources.Executor.NanoCPUs, memoryBytes: oldResources.Executor.MemoryBytes},
		{id: "agent", nanoCPUs: oldResources.Agent.NanoCPUs, memoryBytes: oldResources.Agent.MemoryBytes},
	}
	if !reflect.DeepEqual(updater.calls, want) {
		t.Fatalf("update calls = %#v, want %#v", updater.calls, want)
	}
}

func TestApplyResourcesTransactionPersistsBudgetWithoutContainerUpdates(t *testing.T) {
	oldResources := box.DefaultResources()
	newResources := oldResources
	newResources.AgentVolumeBudgetBytes = 10 << 30
	updater := &fakeResourceUpdater{}
	persisted := false

	if err := applyResourcesTransaction(context.Background(), updater, &box.Box{AgentID: "agent", ExecutorID: "executor"}, oldResources, newResources, func() error {
		persisted = true
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if !persisted || len(updater.calls) != 0 {
		t.Fatalf("persisted/calls = %t/%#v, want true/no calls", persisted, updater.calls)
	}
}

func TestApplyResourcesTransactionRejectsNonRollbackableUnlimitedTransition(t *testing.T) {
	oldResources := box.DefaultResources()
	oldResources.Agent.NanoCPUs = 0
	newResources := oldResources
	newResources.Agent.NanoCPUs = box.DefaultAgentNanoCPUs
	updater := &fakeResourceUpdater{}
	persisted := false

	err := applyResourcesTransaction(context.Background(), updater, &box.Box{Name: "media-bot", AgentID: "agent", ExecutorID: "executor"}, oldResources, newResources, func() error {
		persisted = true
		return nil
	})
	if err == nil || !strings.Contains(err.Error(), "tx9 upgrade media-bot") {
		t.Fatalf("transaction error = %v, want upgrade guidance", err)
	}
	if persisted || len(updater.calls) != 0 {
		t.Fatalf("persisted/calls = %t/%#v, want false/no calls", persisted, updater.calls)
	}
}
