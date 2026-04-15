package cmd

import (
	"fmt"

	"github.com/kairan-app/feeeed/cli/internal/config"
	"github.com/kairan-app/feeeed/cli/internal/graphql"
	"github.com/spf13/cobra"
)

var whoamiCmd = &cobra.Command{
	Use:   "whoami",
	Short: "現在ログインしているユーザーを表示する",
	RunE:  runWhoami,
}

func init() {
	rootCmd.AddCommand(whoamiCmd)
}

func runWhoami(cmd *cobra.Command, args []string) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if cfg.AppPassword == "" {
		return fmt.Errorf("not logged in. Run 'rururu auth login' first")
	}

	endpoint := cfg.Endpoint
	if endpointOverride != "" {
		endpoint = endpointOverride
	}
	if endpoint == "" {
		endpoint = config.DefaultEndpoint
	}

	client := &graphql.Client{Endpoint: endpoint, AppPassword: cfg.AppPassword}
	var resp struct {
		Viewer *struct {
			Name  string `json:"name"`
			Email string `json:"email"`
		} `json:"viewer"`
	}
	if err := client.Query(cmd.Context(), `{ viewer { name email } }`, nil, &resp); err != nil {
		return err
	}
	if resp.Viewer == nil {
		return fmt.Errorf("not authenticated (the App Password may be revoked)")
	}

	fmt.Fprintf(cmd.OutOrStdout(), "%s <%s>\n", resp.Viewer.Name, resp.Viewer.Email)
	return nil
}
