package cmd

import "github.com/spf13/cobra"

var authCmd = &cobra.Command{
	Use:   "auth",
	Short: "App Passwordの管理",
}

func init() {
	rootCmd.AddCommand(authCmd)
}
