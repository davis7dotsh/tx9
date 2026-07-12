package cli

import (
	"bytes"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestRenderOverviewSortsBoxesAndUsesASCII(t *testing.T) {
	boxes := []overviewBox{
		{
			Name: "zebra", State: "stopped", ImageVersion: "0.5.0",
			Agent:          overviewContainer{CPUs: 4, MemoryBytes: 8 << 30, Inspected: true},
			Executor:       overviewContainer{CPUs: 2, MemoryBytes: 2 << 30, Inspected: true},
			AgentVolume:    overviewVolume{UsedBytes: 12 << 20, BudgetKnown: true},
			ExecutorVolume: overviewVolume{UsedBytes: 3 << 20, BudgetKnown: true},
		},
		{
			Name: "alpha", State: "running", ImageVersion: "0.5.0", DashboardURL: "https://alpha.example/",
			Agent:          overviewContainer{CPUs: 6, MemoryBytes: 12 << 30, Inspected: true},
			Executor:       overviewContainer{CPUs: 3, MemoryBytes: 4 << 30, Inspected: true},
			AgentVolume:    overviewVolume{UsedBytes: 70 << 30, BudgetBytes: 64 << 30, BudgetKnown: true},
			ExecutorVolume: overviewVolume{UsedBytes: -1, BudgetKnown: true},
		},
	}

	var out bytes.Buffer
	renderOverview(&out, boxes)
	got := out.String()
	if strings.Index(got, "alpha [RUNNING]") > strings.Index(got, "zebra [STOPPED]") {
		t.Fatalf("boxes are not sorted:\n%s", got)
	}
	for _, want := range []string{"6 CPU / 12GiB RAM", "70GiB / 64GiB budget (OVER)", "? / unlimited", "https://alpha.example/"} {
		if !strings.Contains(got, want) {
			t.Errorf("overview missing %q:\n%s", want, got)
		}
	}
	for _, line := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		if strings.HasPrefix(line, "+") || strings.HasPrefix(line, "|") {
			if len(line) != 72 {
				t.Errorf("panel line width = %d, want 72: %q", len(line), line)
			}
		}
	}
	for len(got) > 0 {
		r, size := utf8.DecodeRuneInString(got)
		if r > 127 {
			t.Fatalf("overview contains non-ASCII rune %q", r)
		}
		got = got[size:]
	}
}

func TestRenderOverviewEmptyState(t *testing.T) {
	var out bytes.Buffer
	renderOverview(&out, nil)
	for _, want := range []string{"0 boxes configured", "no boxes", "tx9 create"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("empty overview missing %q:\n%s", want, out.String())
		}
	}
}

func TestRenderOverviewMarksMissingContainer(t *testing.T) {
	var out bytes.Buffer
	renderOverview(&out, []overviewBox{{
		Name: "partial", State: "crashed",
		Agent:          overviewContainer{CPUs: 4, MemoryBytes: 8 << 30, Inspected: true},
		Executor:       overviewContainer{Missing: true},
		AgentVolume:    overviewVolume{UsedBytes: 0, BudgetKnown: true},
		ExecutorVolume: overviewVolume{UsedBytes: -1, BudgetKnown: true},
	}})
	if !strings.Contains(out.String(), "[executor] missing") {
		t.Fatalf("missing executor not shown:\n%s", out.String())
	}
}

func TestOverviewDistinguishesUnknownAndUnlimited(t *testing.T) {
	if got := formatOverviewContainer(overviewContainer{}); got != "? CPU / ? RAM" {
		t.Fatalf("uninspected container = %q", got)
	}
	if got := formatOverviewContainer(overviewContainer{Inspected: true}); got != "unlimited CPU / unlimited RAM" {
		t.Fatalf("inspected unlimited container = %q", got)
	}
	if got := formatOverviewVolume(overviewVolume{UsedBytes: 1}); got != "1B / ? budget" {
		t.Fatalf("unknown budget = %q", got)
	}
	if got := formatOverviewVolume(overviewVolume{UsedBytes: 1, BudgetKnown: true}); got != "1B / unlimited" {
		t.Fatalf("known unlimited budget = %q", got)
	}
}
