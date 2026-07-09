package cli

import (
	"flag"
	"fmt"

	"github.com/davis7dotsh/tx9/internal/box"
)

type executorConfigFlags struct {
	webBaseURL *string
	publish    *string
	dns        *string
	clear      *bool
}

func addExecutorConfigFlags(fs *flag.FlagSet) executorConfigFlags {
	return executorConfigFlags{
		webBaseURL: fs.String(
			"executor-web-base-url",
			"",
			"public Executor browser origin (or TX9_EXECUTOR_WEB_BASE_URL)",
		),
		publish: fs.String(
			"executor-publish",
			"",
			"fixed Docker host binding as IP:port (or TX9_EXECUTOR_PUBLISH)",
		),
		dns: fs.String(
			"executor-dns",
			"",
			"comma-separated DNS resolver IPs (or TX9_EXECUTOR_DNS)",
		),
		clear: fs.Bool(
			"clear-executor-config",
			false,
			"remove persisted Executor public URL, fixed publish address, and DNS",
		),
	}
}

func (f executorConfigFlags) load(name string) (box.ExecutorConfig, error) {
	if *f.clear && (*f.webBaseURL != "" || *f.publish != "" || *f.dns != "") {
		return box.ExecutorConfig{}, fmt.Errorf("--clear-executor-config cannot be combined with Executor configuration values")
	}
	return box.LoadExecutorConfig(name, box.ExecutorConfigOverrides{
		WebBaseURL: *f.webBaseURL,
		Publish:    *f.publish,
		DNS:        *f.dns,
		Clear:      *f.clear,
	})
}

func (f executorConfigFlags) hasOverrides() bool {
	return *f.webBaseURL != "" || *f.publish != "" || *f.dns != "" || *f.clear
}
