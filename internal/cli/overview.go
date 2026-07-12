package cli

import (
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	units "github.com/docker/go-units"

	"github.com/davis7dotsh/tx9/internal/version"
)

type overviewContainer struct {
	CPUs        float64
	MemoryBytes int64
	Missing     bool
	Inspected   bool
}

type overviewVolume struct {
	UsedBytes   int64
	BudgetBytes int64
	BudgetKnown bool
}

type overviewBox struct {
	Name           string
	State          string
	ImageVersion   string
	DashboardURL   string
	Agent          overviewContainer
	Executor       overviewContainer
	AgentVolume    overviewVolume
	ExecutorVolume overviewVolume
}

func renderOverview(w io.Writer, boxes []overviewBox) {
	boxes = append([]overviewBox(nil), boxes...)
	sort.Slice(boxes, func(i, j int) bool { return boxes[i].Name < boxes[j].Name })

	countLabel := "boxes"
	if len(boxes) == 1 {
		countLabel = "box"
	}
	fmt.Fprintf(w, "tx9 %s - %d %s configured\n\n", version.Version, len(boxes), countLabel)
	if len(boxes) == 0 {
		renderASCIIPanel(w, "no boxes", []string{
			"No boxes are configured on this Docker daemon.",
			"Run `tx9 create` to make one.",
		})
		return
	}

	for i, b := range boxes {
		state := strings.ToUpper(b.State)
		if state == "" {
			state = "UNKNOWN"
		}
		image := b.ImageVersion
		if image == "" {
			image = "?"
		}
		url := b.DashboardURL
		if url == "" {
			url = "-"
		}

		lines := []string{
			"image: " + image,
			fmt.Sprintf("[agent] %s  --->  [executor] %s", formatOverviewContainer(b.Agent), formatOverviewContainer(b.Executor)),
			fmt.Sprintf("data: %s    scratch: %s", formatOverviewVolume(b.AgentVolume), formatOverviewVolume(b.ExecutorVolume)),
			"dashboard: " + url,
		}
		renderASCIIPanel(w, fmt.Sprintf("%s [%s]", b.Name, state), lines)
		if i != len(boxes)-1 {
			fmt.Fprintln(w)
		}
	}
}

func renderASCIIPanel(w io.Writer, title string, lines []string) {
	width := len(title) + 7
	for _, line := range lines {
		if n := utf8.RuneCountInString(line) + 4; n > width {
			width = n
		}
	}
	if width < 72 {
		width = 72
	}
	if width > 100 {
		width = 100
	}
	title = truncateASCII(title, width-7)
	fmt.Fprintf(w, "+-- %s %s+\n", title, strings.Repeat("-", width-len(title)-6))
	for _, line := range lines {
		line = truncateASCII(line, width-4)
		fmt.Fprintf(w, "| %-*s |\n", width-4, line)
	}
	fmt.Fprintf(w, "+%s+\n", strings.Repeat("-", width-2))
}

func formatOverviewContainer(c overviewContainer) string {
	if c.Missing {
		return "missing"
	}
	if !c.Inspected {
		return "? CPU / ? RAM"
	}
	cpu := "? CPU"
	if c.CPUs > 0 {
		cpu = strconv.FormatFloat(c.CPUs, 'f', -1, 64) + " CPU"
	} else if c.CPUs == 0 {
		cpu = "unlimited CPU"
	}
	memory := "? RAM"
	if c.MemoryBytes > 0 {
		memory = units.BytesSize(float64(c.MemoryBytes)) + " RAM"
	} else if c.MemoryBytes == 0 {
		memory = "unlimited RAM"
	}
	return cpu + " / " + memory
}

func formatOverviewVolume(v overviewVolume) string {
	used := "?"
	if v.UsedBytes >= 0 {
		used = units.BytesSize(float64(v.UsedBytes))
	}
	budget := "? budget"
	if v.BudgetKnown && v.BudgetBytes == 0 {
		budget = "unlimited"
	} else if v.BudgetKnown && v.BudgetBytes > 0 {
		budget = units.BytesSize(float64(v.BudgetBytes)) + " budget"
	}
	result := used + " / " + budget
	if v.BudgetKnown && v.BudgetBytes > 0 && v.UsedBytes > v.BudgetBytes {
		result += " (OVER)"
	}
	return result
}

func truncateASCII(value string, max int) string {
	if len(value) <= max {
		return value
	}
	if max <= 3 {
		return value[:max]
	}
	return value[:max-3] + "..."
}
