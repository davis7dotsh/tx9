package box

import (
	"context"
	"math"
	"reflect"
	"testing"

	"github.com/docker/go-units"

	"github.com/davis7dotsh/tx9/internal/state"
)

func TestDefaultResources(t *testing.T) {
	got := DefaultResources()
	want := Resources{
		Agent: ContainerResources{
			NanoCPUs:    4_000_000_000,
			MemoryBytes: 8 * units.GiB,
		},
		Executor: ContainerResources{
			NanoCPUs:    2_000_000_000,
			MemoryBytes: 2 * units.GiB,
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("DefaultResources() = %#v, want %#v", got, want)
	}
}

func TestInspectResourcesPreservesDesiredValuesForMissingContainers(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	const name = "partial"
	want := DefaultResources()
	want.Agent.NanoCPUs = 7_000_000_000
	want.Executor.MemoryBytes = 5 * units.GiB
	if err := state.WriteBoxEnv(name, map[string]string{}); err != nil {
		t.Fatal(err)
	}
	if err := SaveResources(name, want); err != nil {
		t.Fatal(err)
	}

	got, err := InspectResources(context.Background(), nil, &Box{Name: name})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("InspectResources() = %#v, want persisted values %#v", got, want)
	}
}

func TestResourcesPersistPreserveUnknownAndReset(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	const name = "media-bot"
	if err := state.WriteBoxEnv(name, map[string]string{
		"EXECUTOR_MCP_TOKEN": "secret-token",
		"FUTURE_SETTING":     "preserve-me",
	}); err != nil {
		t.Fatal(err)
	}

	want := Resources{
		Agent: ContainerResources{
			NanoCPUs:    3_500_000_000,
			MemoryBytes: 6 * units.GiB,
		},
		Executor: ContainerResources{
			NanoCPUs:    1_250_000_000,
			MemoryBytes: 3 * units.GiB,
		},
		AgentVolumeBudgetBytes:    40 * units.GiB,
		ExecutorVolumeBudgetBytes: 5 * units.GiB,
	}
	if err := SaveResources(name, want); err != nil {
		t.Fatal(err)
	}
	got, err := LoadResources(name)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("LoadResources() = %#v, want %#v", got, want)
	}

	env, err := state.ReadBoxEnv(name)
	if err != nil {
		t.Fatal(err)
	}
	if env["EXECUTOR_MCP_TOKEN"] != "secret-token" || env["FUTURE_SETTING"] != "preserve-me" {
		t.Errorf("unrelated settings were not preserved: %#v", env)
	}

	if err := ResetResources(name); err != nil {
		t.Fatal(err)
	}
	env, err = state.ReadBoxEnv(name)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range resourceEnvKeys {
		if _, ok := env[key]; ok {
			t.Errorf("resource key %s remains after reset", key)
		}
	}
	if env["EXECUTOR_MCP_TOKEN"] != "secret-token" || env["FUTURE_SETTING"] != "preserve-me" {
		t.Errorf("reset discarded unrelated settings: %#v", env)
	}

	got, err = LoadResources(name)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, DefaultResources()) {
		t.Errorf("LoadResources() after reset = %#v, want defaults %#v", got, DefaultResources())
	}
}

func TestResourcesPersistUnlimitedContainerAllocations(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	const name = "unlimited"
	if err := state.WriteBoxEnv(name, map[string]string{}); err != nil {
		t.Fatal(err)
	}

	want := Resources{}
	if err := SaveResources(name, want); err != nil {
		t.Fatal(err)
	}
	got, err := LoadResources(name)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("LoadResources() = %#v, want unlimited values %#v", got, want)
	}
}

func TestLoadResourcesUsesDefaultsForMissingKeys(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	const name = "partial"
	if err := state.WriteBoxEnv(name, map[string]string{
		AgentNanoCPUsEnv:          "1500000000",
		AgentVolumeBudgetBytesEnv: "10737418240",
	}); err != nil {
		t.Fatal(err)
	}

	got, err := LoadResources(name)
	if err != nil {
		t.Fatal(err)
	}
	want := DefaultResources()
	want.Agent.NanoCPUs = 1_500_000_000
	want.AgentVolumeBudgetBytes = 10 * units.GiB
	if !reflect.DeepEqual(got, want) {
		t.Errorf("LoadResources() = %#v, want %#v", got, want)
	}
}

func TestLoadResourcesRejectsInvalidStoredValues(t *testing.T) {
	cases := []struct {
		name  string
		key   string
		value string
	}{
		{name: "not a number", key: AgentMemoryBytesEnv, value: "8GiB"},
		{name: "negative CPU", key: AgentNanoCPUsEnv, value: "-1"},
		{name: "negative budget", key: ExecutorVolumeBudgetBytesEnv, value: "-1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			if err := state.WriteBoxEnv("invalid", map[string]string{tc.key: tc.value}); err != nil {
				t.Fatal(err)
			}
			if _, err := LoadResources("invalid"); err == nil {
				t.Fatal("LoadResources() error = nil, want invalid stored setting error")
			}
		})
	}
}

func TestResourceParsingAndFormatting(t *testing.T) {
	nanoCPUs, err := ParseCPUs("1.5")
	if err != nil {
		t.Fatal(err)
	}
	if nanoCPUs != 1_500_000_000 || FormatCPUs(nanoCPUs) != "1.5" {
		t.Errorf("CPU parse/format = %d/%q", nanoCPUs, FormatCPUs(nanoCPUs))
	}
	if FormatCPUs(0) != "unlimited" {
		t.Errorf("FormatCPUs(0) = %q", FormatCPUs(0))
	}
	for _, value := range []string{"9223372036.854776", "9223372036.854777"} {
		if _, err := ParseCPUs(value); err == nil {
			t.Errorf("ParseCPUs(%q) error = nil, want overflow error", value)
		}
	}
	largeCPUs, err := ParseCPUs("9223372036.854774")
	if err != nil || largeCPUs <= 0 {
		t.Errorf("ParseCPUs(largest safe fixture) = %d, %v", largeCPUs, err)
	}

	bytes, err := ParseBytes("8GiB")
	if err != nil {
		t.Fatal(err)
	}
	if bytes != 8*units.GiB || FormatBytes(bytes) != "8GiB" {
		t.Errorf("byte parse/format = %d/%q", bytes, FormatBytes(bytes))
	}
	if zero, err := ParseBytes("0"); err != nil || zero != 0 {
		t.Errorf("ParseBytes(0) = %d, %v", zero, err)
	}

	budget, err := ParseVolumeBudgetBytes("unlimited")
	if err != nil {
		t.Fatal(err)
	}
	if budget != 0 || FormatVolumeBudget(budget) != "unlimited" {
		t.Errorf("budget parse/format = %d/%q", budget, FormatVolumeBudget(budget))
	}

	for _, value := range []string{"", "0", "-1", "not-a-cpu"} {
		if _, err := ParseCPUs(value); err == nil {
			t.Errorf("ParseCPUs(%q) error = nil", value)
		}
	}
	for _, value := range []string{"", "-1", "lots"} {
		if _, err := ParseBytes(value); err == nil {
			t.Errorf("ParseBytes(%q) error = nil", value)
		}
	}
}

func TestResourcesEnforceDockerMinimumMemory(t *testing.T) {
	resources := DefaultResources()
	resources.Agent.NanoCPUs = 0
	resources.Agent.MemoryBytes = 0
	if err := resources.Validate(); err != nil {
		t.Fatalf("Validate() unlimited resources = %v", err)
	}
	resources.Agent.NanoCPUs = -1
	if err := resources.Validate(); err == nil {
		t.Fatal("Validate() error = nil for negative CPUs")
	}
	resources.Agent.NanoCPUs = 0
	resources.Agent.MemoryBytes = MinimumMemoryBytes - 1
	if err := resources.Validate(); err == nil {
		t.Fatal("Validate() error = nil below Docker's minimum memory")
	}
	resources.Agent.MemoryBytes = MinimumMemoryBytes
	if err := resources.Validate(); err != nil {
		t.Fatalf("Validate() at Docker's minimum = %v", err)
	}

	if _, err := ParseMemoryBytes("5MiB"); err == nil {
		t.Fatal("ParseMemoryBytes(5MiB) error = nil")
	}
	bytes, err := ParseMemoryBytes("6MiB")
	if err != nil {
		t.Fatal(err)
	}
	if bytes != MinimumMemoryBytes {
		t.Errorf("ParseMemoryBytes(6MiB) = %d, want %d", bytes, MinimumMemoryBytes)
	}
}

func TestResourcesRejectMemoryThatCannotPreserveDefaultSwapAllowance(t *testing.T) {
	resources := DefaultResources()
	resources.Agent.MemoryBytes = math.MaxInt64/2 + 1
	if err := resources.Validate(); err == nil {
		t.Fatal("Validate() error = nil for memory that cannot be doubled")
	}
}

func TestAgentContainerSpecUsesConfiguredResourcesAndBoxName(t *testing.T) {
	want := ContainerResources{NanoCPUs: 750_000_000, MemoryBytes: 3 * units.GiB}
	spec := newAgentContainerSpecWithResources(
		"media-bot", "tx9-box:test", "token", "test", "network", "agent-volume",
		nil, nil, want,
	)
	if spec.NanoCPUs != want.NanoCPUs || spec.MemoryBytes != want.MemoryBytes {
		t.Errorf("container resources = %d/%d, want %d/%d", spec.NanoCPUs, spec.MemoryBytes, want.NanoCPUs, want.MemoryBytes)
	}
	foundBoxName := false
	for _, entry := range spec.Env {
		if entry == "TX9_BOX_NAME=media-bot" {
			foundBoxName = true
			break
		}
	}
	if !foundBoxName {
		t.Errorf("Env = %#v, want TX9_BOX_NAME", spec.Env)
	}
}
