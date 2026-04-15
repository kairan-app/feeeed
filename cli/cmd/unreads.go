package cmd

import "github.com/spf13/cobra"

var unreadsCmd = &cobra.Command{
	Use:   "unreads",
	Short: "未読記事の操作",
}

func init() {
	rootCmd.AddCommand(unreadsCmd)
}
