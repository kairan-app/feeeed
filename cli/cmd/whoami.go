package cmd

import (
	"fmt"

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
	client, profileName, err := authedClient()
	if err != nil {
		return err
	}

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
		return fmt.Errorf("not authenticated (the App Password may be revoked) [profile: %s]", profileName)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "%s <%s> (profile: %s)\n", resp.Viewer.Name, resp.Viewer.Email, profileName)
	return nil
}
