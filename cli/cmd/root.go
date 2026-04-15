package cmd

import (
	"fmt"
	"os"

	"github.com/kairan-app/feeeed/cli/internal/config"
	"github.com/kairan-app/feeeed/cli/internal/graphql"
	"github.com/spf13/cobra"
)

// グローバルフラグ。各サブコマンドから参照する。
var (
	endpointOverride string
	profileFlag      string
)

var rootCmd = &cobra.Command{
	Use:   "rururu",
	Short: "rururu CLI",
	Long:  "rururu: AI Agentフレンドリーに rururu (feeeed) を操作するための CLI",
	// 実行時エラーに Usage を付けない(`--help` 経由では普通に出る)
	SilenceUsage: true,
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func init() {
	rootCmd.PersistentFlags().StringVar(&endpointOverride, "endpoint", "", "GraphQLエンドポイントを一時的に上書き")
	rootCmd.PersistentFlags().StringVar(&profileFlag, "profile", "", "使用するプロファイル名 (env: RURURU_PROFILE)")
}

// authedClient は現在のプロファイルから認証済みのGraphQLクライアントを構築する。
// --endpoint で上書きされていればそれを優先する。
func authedClient() (*graphql.Client, string, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, "", err
	}
	name, profile, err := cfg.CurrentProfile(profileFlag)
	if err != nil {
		return nil, "", err
	}
	if profile.AppPassword == "" {
		return nil, "", fmt.Errorf("profile %q has no App Password. Run 'rururu auth login --profile %s'", name, name)
	}

	endpoint := profile.Endpoint
	if endpointOverride != "" {
		endpoint = endpointOverride
	}
	if endpoint == "" {
		endpoint = config.DefaultEndpoint
	}
	return &graphql.Client{Endpoint: endpoint, AppPassword: profile.AppPassword}, name, nil
}
