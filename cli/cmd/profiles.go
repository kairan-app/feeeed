package cmd

import (
	"fmt"

	"github.com/kairan-app/feeeed/cli/internal/config"
	"github.com/spf13/cobra"
)

var profilesCmd = &cobra.Command{
	Use:   "profiles",
	Short: "プロファイルの管理",
}

var profilesListCmd = &cobra.Command{
	Use:   "list",
	Short: "登録済みのプロファイル一覧を表示する",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}
		if len(cfg.Profiles) == 0 {
			fmt.Fprintln(cmd.OutOrStdout(), "(no profiles)")
			return nil
		}
		for _, name := range cfg.SortedProfileNames() {
			marker := "  "
			if name == cfg.Default {
				marker = "* "
			}
			endpoint := cfg.Profiles[name].Endpoint
			if endpoint == "" {
				endpoint = config.DefaultEndpoint
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%s%s\t%s\n", marker, name, endpoint)
		}
		return nil
	},
}

var profilesUseCmd = &cobra.Command{
	Use:   "use <profile>",
	Short: "デフォルトプロファイルを切り替える",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}
		name := args[0]
		if _, ok := cfg.Profiles[name]; !ok {
			return fmt.Errorf("profile %q not found", name)
		}
		cfg.Default = name
		if err := config.Save(cfg); err != nil {
			return err
		}
		fmt.Fprintf(cmd.OutOrStdout(), "Default profile: %s\n", name)
		return nil
	},
}

func init() {
	profilesCmd.AddCommand(profilesListCmd)
	profilesCmd.AddCommand(profilesUseCmd)
	rootCmd.AddCommand(profilesCmd)
}
