package cmd

import (
	"fmt"

	"github.com/kairan-app/feeeed/cli/internal/config"
	"github.com/spf13/cobra"
)

var authLogoutCmd = &cobra.Command{
	Use:   "logout",
	Short: "保存されたApp Passwordを削除する",
	RunE: func(cmd *cobra.Command, args []string) error {
		if err := config.Delete(); err != nil {
			return fmt.Errorf("failed to delete config: %w", err)
		}
		fmt.Fprintln(cmd.OutOrStdout(), "Logged out.")
		return nil
	},
}

func init() {
	authCmd.AddCommand(authLogoutCmd)
}
