package cmd

import (
	"fmt"

	"github.com/kairan-app/feeeed/cli/internal/config"
	"github.com/spf13/cobra"
)

var authLogoutCmd = &cobra.Command{
	Use:   "logout",
	Short: "プロファイルを削除する",
	Long: `指定したプロファイルを削除する。

--profile を指定しなければ現在のデフォルトプロファイルを削除する。
最後の1つを削除した場合、設定ファイル全体は残るが空になる。`,
	RunE: runAuthLogout,
}

func init() {
	authCmd.AddCommand(authLogoutCmd)
}

func runAuthLogout(cmd *cobra.Command, args []string) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if len(cfg.Profiles) == 0 {
		fmt.Fprintln(cmd.OutOrStdout(), "Already logged out.")
		return nil
	}

	name, err := cfg.ResolveProfileName(profileFlag)
	if err != nil {
		return err
	}
	if _, ok := cfg.Profiles[name]; !ok {
		return fmt.Errorf("profile %q not found", name)
	}

	delete(cfg.Profiles, name)
	if cfg.Default == name {
		cfg.Default = ""
		// 残りが1つなら、それを新しいデフォルトに昇格させる
		if len(cfg.Profiles) == 1 {
			for n := range cfg.Profiles {
				cfg.Default = n
			}
		}
	}

	if err := config.Save(cfg); err != nil {
		return fmt.Errorf("failed to save config: %w", err)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Logged out (profile: %s)\n", name)
	return nil
}
