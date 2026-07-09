package cli

import (
	"reflect"
	"testing"
)

func TestGatewayHBArgs(t *testing.T) {
	tests := []struct {
		name      string
		action    string
		confirmed bool
		want      [][]string
		wantErr   bool
	}{
		{name: "status", action: "status", want: [][]string{{"status"}}},
		{name: "disable", action: "disable", want: [][]string{{"gateway-disable"}}},
		{name: "enable requires confirmation", action: "enable", wantErr: true},
		{
			name:      "enable",
			action:    "enable",
			confirmed: true,
			want: [][]string{
				{"gateway-disable"},
				{
					"gateway-enable",
					"--confirm-single-writer",
					singleWriterConfirmation,
				},
			},
		},
		{name: "unknown", action: "restart", wantErr: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := gatewayHBCommands(tc.action, tc.confirmed)
			if (err != nil) != tc.wantErr {
				t.Fatalf("error = %v, wantErr %v", err, tc.wantErr)
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("gatewayHBCommands() = %#v, want %#v", got, tc.want)
			}
		})
	}
}
