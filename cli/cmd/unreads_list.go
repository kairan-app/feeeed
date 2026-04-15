package cmd

import (
	"encoding/json"
	"fmt"

	"github.com/kairan-app/feeeed/cli/internal/config"
	"github.com/kairan-app/feeeed/cli/internal/graphql"
	"github.com/spf13/cobra"
)

var (
	unreadsListRangeDays         int
	unreadsListChannelGroupID    string
	unreadsListSubscriptionTagID string
	unreadsListLimit             int
	unreadsListBefore            string
	unreadsListJSON              bool
)

var unreadsListCmd = &cobra.Command{
	Use:   "list",
	Short: "未読記事の一覧を表示する",
	Long: `購読中チャンネルの記事のうち、自分のpawprint/skipが付いてないものを新しい順に表示する。

ページング:
  最終行に表示される --before <id> を渡すと続きが取れる。`,
	RunE: runUnreadsList,
}

func init() {
	unreadsListCmd.Flags().IntVar(&unreadsListRangeDays, "range-days", 3, "何日前までの記事を対象にするか (1-365)")
	unreadsListCmd.Flags().StringVar(&unreadsListChannelGroupID, "channel-group", "", "ChannelGroup IDで絞り込み")
	unreadsListCmd.Flags().StringVar(&unreadsListSubscriptionTagID, "tag", "", "SubscriptionTag IDで絞り込み")
	unreadsListCmd.Flags().IntVar(&unreadsListLimit, "limit", 50, "取得件数 (1-100)")
	unreadsListCmd.Flags().StringVar(&unreadsListBefore, "before", "", "このIDより古い記事から表示(ページング用)")
	unreadsListCmd.Flags().BoolVar(&unreadsListJSON, "json", false, "JSON形式で出力")
	unreadsCmd.AddCommand(unreadsListCmd)
}

type unreadItem struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	URL         string `json:"url"`
	PublishedAt string `json:"publishedAt"`
	Channel     struct {
		ID    string `json:"id"`
		Title string `json:"title"`
	} `json:"channel"`
}

func runUnreadsList(cmd *cobra.Command, args []string) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if cfg.AppPassword == "" {
		return fmt.Errorf("not logged in. Run 'rururu auth login' first")
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
		"rangeDays": unreadsListRangeDays,
		"first":     unreadsListLimit,
	}
	if unreadsListChannelGroupID != "" {
		vars["channelGroupId"] = unreadsListChannelGroupID
	}
	if unreadsListSubscriptionTagID != "" {
		vars["subscriptionTagId"] = unreadsListSubscriptionTagID
	}
	if unreadsListBefore != "" {
		vars["before"] = unreadsListBefore
	}

	query := `query($rangeDays: Int!, $first: Int!, $before: ID, $channelGroupId: ID, $subscriptionTagId: ID) {
  unreadItems(
    rangeDays: $rangeDays,
    first: $first,
    before: $before,
    channelGroupId: $channelGroupId,
    subscriptionTagId: $subscriptionTagId
  ) {
    id
    title
    url
    publishedAt
    channel { id title }
  }
}`

	var resp struct {
		UnreadItems []unreadItem `json:"unreadItems"`
	}
	if err := client.Query(cmd.Context(), query, vars, &resp); err != nil {
		return err
	}

	out := cmd.OutOrStdout()
	if unreadsListJSON {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(resp.UnreadItems)
	}

	if len(resp.UnreadItems) == 0 {
		fmt.Fprintln(out, "(no unread items)")
		return nil
	}

	for _, i := range resp.UnreadItems {
		ts := formatTime(i.PublishedAt)
		fmt.Fprintf(out, "%s  %s  「%s」  (%s)  %s\n",
			ts, i.ID, i.Title, i.Channel.Title, i.URL)
	}

	if len(resp.UnreadItems) == unreadsListLimit {
		oldest := resp.UnreadItems[len(resp.UnreadItems)-1].ID
		fmt.Fprintf(out, "\n次のページ: rururu unreads list --range-days %d --limit %d --before %s\n",
			unreadsListRangeDays, unreadsListLimit, oldest)
	}
	return nil
}
