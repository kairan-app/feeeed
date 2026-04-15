package cmd

import "github.com/spf13/cobra"

var pawprintsCmd = &cobra.Command{
	Use:   "pawprints",
	Short: "足あと(Pawprint)の操作",
}

func init() {
	rootCmd.AddCommand(pawprintsCmd)
}
