package cmd

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

var (
	pawprintsListScope  string
	pawprintsListLimit  int
	pawprintsListBefore string
	pawprintsListSince  string
	pawprintsListUntil  string
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

期間フィルタ(--since/--until):
  - YYYY-MM-DD 形式で渡すと、ローカルタイムゾーンの
    since=その日の0:00:00、until=その日の23:59:59 として扱う。
  - フルRFC3339(例: 2026-04-15T10:00:00+09:00)でも受け付ける。

ページング:
  最終行に表示される --before <id> を渡すと続きが取れる。`,
	RunE: runPawprintsList,
}

func init() {
	pawprintsListCmd.Flags().StringVar(&pawprintsListScope, "scope", "my", "表示スコープ (my|all|to_me)")
	pawprintsListCmd.Flags().IntVar(&pawprintsListLimit, "limit", 50, "取得件数 (1-100)")
	pawprintsListCmd.Flags().StringVar(&pawprintsListBefore, "before", "", "このIDより古い足あとから表示(ページング用)")
	pawprintsListCmd.Flags().StringVar(&pawprintsListSince, "since", "", "この日時以降(含む)に作成された足あとに絞る")
	pawprintsListCmd.Flags().StringVar(&pawprintsListUntil, "until", "", "この日時以前(含む)に作成された足あとに絞る")
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
	scopeEnum, err := pawprintScopeEnum(pawprintsListScope)
	if err != nil {
		return err
	}

	since, err := parseTimeFlag(pawprintsListSince, startOfDay)
	if err != nil {
		return fmt.Errorf("--since: %w", err)
	}
	until, err := parseTimeFlag(pawprintsListUntil, endOfDay)
	if err != nil {
		return fmt.Errorf("--until: %w", err)
	}

	client, _, err := authedClient()
	if err != nil {
		return err
	}
	vars := map[string]any{
		"scope": scopeEnum,
		"first": pawprintsListLimit,
	}
	if pawprintsListBefore != "" {
		vars["before"] = pawprintsListBefore
	}
	if since != "" {
		vars["since"] = since
	}
	if until != "" {
		vars["until"] = until
	}

	query := `query($scope: PawprintScope!, $first: Int!, $before: ID, $since: ISO8601DateTime, $until: ISO8601DateTime) {
  pawprints(scope: $scope, first: $first, before: $before, since: $since, until: $until) {
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
		next := fmt.Sprintf("rururu pawprints list --scope %s --limit %d --before %q",
			pawprintsListScope, pawprintsListLimit, oldest)
		if pawprintsListSince != "" {
			next += fmt.Sprintf(" --since %q", pawprintsListSince)
		}
		if pawprintsListUntil != "" {
			next += fmt.Sprintf(" --until %q", pawprintsListUntil)
		}
		fmt.Fprintf(out, "\n次のページ: %s\n", next)
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

type dateKind int

const (
	startOfDay dateKind = iota
	endOfDay
)

// parseTimeFlag は --since/--until で受け取った文字列をRFC3339へ正規化する。
// 空文字なら空文字を返す。YYYY-MM-DD形式なら kind に応じて日の開始/終了で補う(ローカルtz)。
// 既にRFC3339形式ならそのまま返す。
func parseTimeFlag(s string, kind dateKind) (string, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", nil
	}
	if t, err := time.ParseInLocation("2006-01-02", s, time.Local); err == nil {
		if kind == endOfDay {
			t = t.AddDate(0, 0, 1).Add(-time.Nanosecond)
		}
		return t.Format(time.RFC3339Nano), nil
	}
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t.Format(time.RFC3339Nano), nil
	}
	return "", fmt.Errorf("invalid time %q (expected YYYY-MM-DD or RFC3339)", s)
}
