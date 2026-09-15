require "test_helper"

class ChannelWithRecentItemsTest < ActiveSupport::TestCase
  test "exposes the newest items of each channel, newest first" do
    channel = create(:channel)
    items = create_items(channel, 5)

    result = Channel.with_recent_items(items_per_channel: 3).find { |c| c.id == channel.id }

    assert_equal items.last(3).reverse.map(&:id), result.recent_items.map(&:id)
  end

  test "orders channels by their newest item" do
    stale = create(:channel)
    fresh = create(:channel)
    create_items(stale, 1)
    create_items(fresh, 1)

    ids = Channel.with_recent_items.map(&:id)

    assert_operator ids.index(fresh.id), :<, ids.index(stale.id)
  end

  test "omits channels that have no items" do
    empty = create(:channel)
    create_items(create(:channel), 1)

    assert_not_includes Channel.with_recent_items.map(&:id), empty.id
  end

  test "scans a bounded number of rows regardless of how many items a channel holds" do
    channel = create(:channel)
    create_items(channel, 200)

    scanned = max_scanned_rows_for_item_lookup { Channel.with_recent_items(items_per_channel: 3) }

    assert_operator scanned, :<=, 50,
      "the item lookup scanned #{scanned} rows to return 3 per channel; " \
      "it should read only the newest rows via the channel_id/id index"
  end

  private

  def create_items(channel, count)
    now = Time.current
    rows = count.times.map do |i|
      {
        channel_id: channel.id,
        guid: "guid-#{channel.id}-#{i}",
        title: "Item #{i}",
        url: "https://example.com/#{channel.id}/#{i}",
        published_at: now - (count - i).minutes,
        created_at: now,
        updated_at: now
      }
    end
    Item.insert_all!(rows)
    # 統計情報が無いとプランナがindexの絞り込みを見積もれず、
    # スキャン行数の検証がプランナの気分次第になってしまう
    Item.connection.execute("ANALYZE items")
    Item.where(channel_id: channel.id).order(:id).to_a
  end

  # Runs the query that loads items for the ranked channels through EXPLAIN ANALYZE
  # and reports the largest number of rows any plan node actually touched.
  def max_scanned_rows_for_item_lookup
    sql = capture_sql { yield }.find { |q| q.match?(/\bitems\b/i) && !q.match?(/\bchannels\b/i) }
    assert sql, "expected a query that reads items for the ranked channels"

    plan = JSON.parse(Item.connection.select_value("EXPLAIN (ANALYZE, FORMAT JSON) #{sql}"))
    max_actual_rows(plan.first["Plan"])
  end

  def max_actual_rows(node)
    children = node["Plans"] || []
    [ node["Actual Rows"].to_i, *children.map { |child| max_actual_rows(child) } ].max
  end

  def capture_sql
    queries = []
    callback = ->(_name, _start, _finish, _id, payload) do
      queries << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end
end
