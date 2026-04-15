package cmd

import (
	"bufio"
	"fmt"
	"net/url"
	"os"
	"strings"

	"github.com/kairan-app/feeeed/cli/internal/config"
	"github.com/kairan-app/feeeed/cli/internal/graphql"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

var authLoginCmd = &cobra.Command{
	Use:   "login",
	Short: "App Passwordを登録する(プロファイル別)",
	Long: `App Passwordを登録する。

--profile でプロファイル名を指定できる(指定しなければ "default")。
新規プロファイルを作成した場合、デフォルトプロファイルが未設定なら自動で設定される。`,
	RunE: runAuthLogin,
}

func init() {
	authCmd.AddCommand(authLoginCmd)
}

func runAuthLogin(cmd *cobra.Command, args []string) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	profileName := profileFlag
	if profileName == "" {
		profileName = config.DefaultProfileName
	}
	existing := cfg.Profiles[profileName]

	defaultEndpoint := existing.Endpoint
	if endpointOverride != "" {
		defaultEndpoint = endpointOverride
	}
	if defaultEndpoint == "" {
		defaultEndpoint = config.DefaultEndpoint
	}

	reader := bufio.NewReader(os.Stdin)

	fmt.Fprintf(cmd.OutOrStdout(), "Profile: %s\n", profileName)
	fmt.Fprintf(cmd.OutOrStdout(), "Endpoint [%s]: ", defaultEndpoint)
	line, err := reader.ReadString('\n')
	if err != nil {
		return err
	}
	endpoint := strings.TrimSpace(line)
	if endpoint == "" {
		endpoint = defaultEndpoint
	}

	if link := appPasswordsURL(endpoint); link != "" {
		fmt.Fprintf(cmd.OutOrStdout(), "\nApp Passwordは %s で発行できます。\n発行後、この画面に貼り付けてください。\n\n", link)
	}

	fmt.Fprint(cmd.OutOrStdout(), "App Password: ")
	pwBytes, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(cmd.OutOrStdout())
	if err != nil {
		return fmt.Errorf("failed to read App Password: %w", err)
	}
	appPassword := strings.TrimSpace(string(pwBytes))
	if appPassword == "" {
		return fmt.Errorf("App Password is required")
	}

	client := &graphql.Client{Endpoint: endpoint, AppPassword: appPassword}
	var resp struct {
		Viewer *struct {
			Name string `json:"name"`
		} `json:"viewer"`
	}
	if err := client.Query(cmd.Context(), `{ viewer { name } }`, nil, &resp); err != nil {
		return fmt.Errorf("failed to authenticate: %w", err)
	}
	if resp.Viewer == nil {
		return fmt.Errorf("failed to authenticate: the App Password may be invalid or revoked")
	}

	if cfg.Profiles == nil {
		cfg.Profiles = map[string]config.Profile{}
	}
	cfg.Profiles[profileName] = config.Profile{Endpoint: endpoint, AppPassword: appPassword}
	if cfg.Default == "" {
		cfg.Default = profileName
	}

	if err := config.Save(cfg); err != nil {
		return fmt.Errorf("failed to save config: %w", err)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "Logged in as %s (profile: %s)\n", resp.Viewer.Name, profileName)
	return nil
}

// appPasswordsURL は GraphQL エンドポイントURLから /my/app_passwords の案内URLを導く。
// スキーム/ホストが取れない場合は空文字を返して呼び出し側で案内をスキップさせる。
func appPasswordsURL(endpoint string) string {
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return ""
	}
	return fmt.Sprintf("%s://%s/my/app_passwords", u.Scheme, u.Host)
}
