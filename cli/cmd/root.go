package cmd

import (
	"os"

	"github.com/spf13/cobra"
)

// --endpoint のグローバル値。各サブコマンドから参照する。
var endpointOverride string

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
}
