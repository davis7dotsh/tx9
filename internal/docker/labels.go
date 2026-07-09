package docker

// Label keys tx9 stamps on every Docker object it creates, so `tx9 list`
// can reconstruct truth from the daemon even if ~/.tx9 is lost (decision 2).
const (
	LabelManaged            = "tx9"                       // "1" on every tx9-managed object
	LabelBox                = "tx9.box"                   // box name
	LabelVersion            = "tx9.version"               // image/CLI version that created the object
	LabelRole               = "tx9.role"                  // "agent" or "executor"
	LabelExecutorWebBaseURL = "tx9.executor-web-base-url" // public Executor browser origin
)

// Roles for LabelRole.
const (
	RoleAgent    = "agent"
	RoleExecutor = "executor"
)

// BoxLabels returns the standard label set for an object belonging to box
// name, tagged with version, playing role (RoleAgent/RoleExecutor, or ""
// for objects — like the per-box network — that aren't container-specific).
func BoxLabels(name, version, role string) map[string]string {
	labels := map[string]string{
		LabelManaged: "1",
		LabelBox:     name,
		LabelVersion: version,
	}
	if role != "" {
		labels[LabelRole] = role
	}
	return labels
}
