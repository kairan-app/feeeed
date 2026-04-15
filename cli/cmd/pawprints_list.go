package cmd

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/kairan-app/feeeed/cli/internal/config"
	"github.com/kairan-app/feeeed/cli/internal/graphql"
	"github.com/spf13/cobra"
)

var (
	pawprintsListScope  string
	pawprintsListLimit  int
	pawprintsListBefore string
	pawprintsListJSON   bool
)

var pawprintsListCmd = &cobra.Command{
	Use:   "list",
	Short: "足あとの一覧を表示する",
	Long: `足あとの一覧を新しい順に表示する。

スコープ:
  my     自分の足あと(デフォルト)
  all    全ユーザーの足あと
  to_me  自分が所有するチャンネルへの足あと

ページング:
  最終行に表示される --before <id> を渡すと続きが取れる。`,
	RunE: runPawprintsList,
}

func init() {
	pawprintsListCmd.Flags().StringVar(&pawprintsListScope, "scope", "my", "表示スコープ (my|all|to_me)")
	pawprintsListCmd.Flags().IntVar(&pawprintsListLimit, "limit", 50, "取得件数 (1-100)")
	pawprintsListCmd.Flags().StringVar(&pawprintsListBefore, "before", "", "このIDより古い足あとから表示(ページング用)")
	pawprintsListCmd.Flags().BoolVar(&pawprintsListJSON, "json", false, "JSON形式で出力")
	pawprintsCmd.AddCommand(pawprintsListCmd)
}

type pawprintListItem struct {
	ID        string `json:"id"`
	Memo      string `json:"memo"`
	CreatedAt string `json:"createdAt"`
	User      struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"user"`
	Item struct {
		Title   string `json:"title"`
		URL     string `json:"url"`
		Channel struct {
			Title string `json:"title"`
		} `json:"channel"`
	} `json:"item"`
}

func runPawprintsList(cmd *cobra.Command, args []string) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if cfg.AppPassword == "" {
		return fmt.Errorf("not logged in. Run 'rururu auth login' first")
	}

	scopeEnum, err := pawprintScopeEnum(pawprintsListScope)
	if err != nil {
		return err
	}

	endpoint := cfg.Endpoint
	if endpointOverride != "" {
		endpoint = endpointOverride
	}
	if endpoint == "" {
		endpoint = config.DefaultEndpoint
	}

	client := &graphql.Client{Endpoint: endpoint, AppPassword: cfg.AppPassword}
	vars := map[string]any{
		"scope": scopeEnum,
		"first": pawprintsListLimit,
	}
	if pawprintsListBefore != "" {
		vars["before"] = pawprintsListBefore
	}

	query := `query($scope: PawprintScope!, $first: Int!, $before: ID) {
  pawprints(scope: $scope, first: $first, before: $before) {
    id
    memo
    createdAt
    user { id name }
    item { title url channel { title } }
  }
}`

	var resp struct {
		Pawprints []pawprintListItem `json:"pawprints"`
	}
	if err := client.Query(cmd.Context(), query, vars, &resp); err != nil {
		return err
	}

	out := cmd.OutOrStdout()
	if pawprintsListJSON {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(resp.Pawprints)
	}

	if len(resp.Pawprints) == 0 {
		fmt.Fprintln(out, "(no pawprints)")
		return nil
	}

	for _, p := range resp.Pawprints {
		ts := formatTime(p.CreatedAt)
		line := fmt.Sprintf("%s  %s  %s  「%s」  (%s)",
			ts, p.ID, p.User.Name, p.Item.Title, p.Item.Channel.Title)
		if memo := strings.TrimSpace(p.Memo); memo != "" {
			line += "  💬 " + memo
		}
		fmt.Fprintln(out, line)
	}

	if len(resp.Pawprints) == pawprintsListLimit {
		oldest := resp.Pawprints[len(resp.Pawprints)-1].ID
		fmt.Fprintf(out, "\n次のページ: rururu pawprints list --scope %s --limit %d --before %s\n",
			pawprintsListScope, pawprintsListLimit, oldest)
	}
	return nil
}

func pawprintScopeEnum(s string) (string, error) {
	switch strings.ToLower(s) {
	case "my":
		return "MY", nil
	case "all":
		return "ALL", nil
	case "to_me", "to-me", "tome":
		return "TO_ME", nil
	default:
		return "", fmt.Errorf("unknown scope %q (expected: my|all|to_me)", s)
	}
}

func formatTime(iso string) string {
	t, err := time.Parse(time.RFC3339, iso)
	if err != nil {
		return iso
	}
	return t.Local().Format("2006-01-02 15:04")
}
