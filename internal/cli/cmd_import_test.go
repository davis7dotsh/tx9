package cli

import (
	"strings"
	"testing"
)

func TestImportRejectsExtraArgumentsBeforeReadingArchive(t *testing.T) {
	if err := cmdImport([]string{"first.tx9", "second.tx9"}); err == nil || !strings.Contains(err.Error(), "exactly one archive") {
		t.Fatalf("import did not reject extra archive arguments: %v", err)
	}
}
