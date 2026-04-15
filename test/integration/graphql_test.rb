require "test_helper"

class GraphqlTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:user)
    @channel = create(:channel)
    @user.subscribe(@channel)
    @plain, @app_password = AppPassword.issue!(user: @user, name: "MacBook")
  end

  def post_graphql(query, token: nil)
    headers = { "Content-Type" => "application/json" }
    headers["Authorization"] = "Bearer #{token}" if token

    post "/graphql",
      params: { query: query }.to_json,
      headers: headers
  end

  test "viewer returns nil when no Authorization header" do
    post_graphql("{ viewer { id } }")

    body = JSON.parse(response.body)
    assert_nil body.dig("data", "viewer")
  end

  test "viewer returns nil for invalid token" do
    post_graphql("{ viewer { id } }", token: "rururu_invalid")

    body = JSON.parse(response.body)
    assert_nil body.dig("data", "viewer")
  end

  test "viewer returns authenticated user" do
    post_graphql("{ viewer { id name email } }", token: @plain)

    body = JSON.parse(response.body)
    assert_equal @user.name, body.dig("data", "viewer", "name")
    assert_equal @user.email, body.dig("data", "viewer", "email")
  end

  test "viewer.subscriptions returns subscribed channels" do
    query = "{ viewer { subscriptions { channel { id title feedUrl } } } }"
    post_graphql(query, token: @plain)

    body = JSON.parse(response.body)
    channels = body.dig("data", "viewer", "subscriptions").map { |s| s["channel"] }
    assert_equal [ @channel.title ], channels.map { |c| c["title"] }
    assert_equal [ @channel.feed_url ], channels.map { |c| c["feedUrl"] }
  end

  test "revoked App Password does not authenticate" do
    @app_password.revoke!
    post_graphql("{ viewer { id } }", token: @plain)

    body = JSON.parse(response.body)
    assert_nil body.dig("data", "viewer")
  end

  test "App Password last_used_at is updated on successful auth" do
    assert_nil @app_password.last_used_at

    travel 1.minute do
      post_graphql("{ viewer { id } }", token: @plain)
    end

    assert_not_nil @app_password.reload.last_used_at
  end

  test "authenticated request creates an Ahoy event tied to the user" do
    assert_difference "Ahoy::Event.where(name: 'graphql#execute').count", 1 do
      post_graphql("query GetViewer { viewer { id name } }", token: @plain)
    end

    event = Ahoy::Event.where(name: "graphql#execute").last
    assert_equal @user.id, event.user_id
    assert_equal "GetViewer", event.properties["operation_name"]
    assert_equal [ "viewer" ], event.properties["root_fields"]
    assert_equal true, event.properties["authenticated"]
  end

  test "unauthenticated request creates an Ahoy event without a user" do
    assert_difference "Ahoy::Event.where(name: 'graphql#execute').count", 1 do
      post_graphql("{ viewer { id } }")
    end

    event = Ahoy::Event.where(name: "graphql#execute").last
    assert_nil event.user_id
    assert_equal false, event.properties["authenticated"]
    assert_equal [ "viewer" ], event.properties["root_fields"]
  end

  test "pawprints with scope MY returns only pawprints of the current user" do
    other = create(:user)
    item_a = create(:item, channel: @channel)
    item_b = create(:item, channel: @channel)
    @user.paw(item_a, memo: "mine")
    other.paw(item_b, memo: "theirs")

    query = "{ pawprints(scope: MY) { memo user { id } item { title } } }"
    post_graphql(query, token: @plain)

    body = JSON.parse(response.body)
    pps = body.dig("data", "pawprints")
    assert_equal [ "mine" ], pps.map { |p| p["memo"] }
    assert_equal [ @user.id.to_s ], pps.map { |p| p.dig("user", "id") }
  end

  test "pawprints orders by id desc and respects first" do
    items = Array.new(3) { create(:item, channel: @channel) }
    items.each { |i| @user.paw(i, memo: nil) }

    query = "{ pawprints(scope: MY, first: 2) { item { title } } }"
    post_graphql(query, token: @plain)

    body = JSON.parse(response.body)
    titles = body.dig("data", "pawprints").map { |p| p.dig("item", "title") }
    assert_equal [ items[2].title, items[1].title ], titles
  end

  test "pawprints supports keyset pagination via before" do
    items = Array.new(3) { create(:item, channel: @channel) }
    pps = items.map { |i| @user.paw(i, memo: nil) }
    middle_id = pps[1].id

    query = "{ pawprints(scope: MY, before: \"#{middle_id}\") { id } }"
    post_graphql(query, token: @plain)

    body = JSON.parse(response.body)
    ids = body.dig("data", "pawprints").map { |p| p["id"] }
    assert_equal [ pps[0].id.to_s ], ids
  end

  test "pawprints with scope MY returns empty when unauthenticated" do
    @user.paw(create(:item, channel: @channel), memo: "x")

    post_graphql("{ pawprints(scope: MY) { id } }")

    body = JSON.parse(response.body)
    assert_equal [], body.dig("data", "pawprints")
  end

  test "unreadItems returns subscribed items not pawprinted/skipped" do
    fresh = create(:item, channel: @channel)
    pawed = create(:item, channel: @channel)
    @user.paw(pawed, memo: nil)
    skipped = create(:item, channel: @channel)
    ItemSkip.create!(user: @user, item: skipped)
    other_channel = create(:channel)
    create(:item, channel: other_channel)

    query = "{ unreadItems { id title channel { id } } }"
    post_graphql(query, token: @plain)

    body = JSON.parse(response.body)
    ids = body.dig("data", "unreadItems").map { |i| i["id"] }
    assert_equal [ fresh.id.to_s ], ids
  end

  test "unreadItems excludes items older than rangeDays" do
    recent = create(:item, channel: @channel)
    old = create(:item, channel: @channel)
    old.update_column(:created_at, 10.days.ago)

    query = "{ unreadItems(rangeDays: 3) { id } }"
    post_graphql(query, token: @plain)

    body = JSON.parse(response.body)
    ids = body.dig("data", "unreadItems").map { |i| i["id"] }
    assert_equal [ recent.id.to_s ], ids
  end

  test "unreadItems orders by id desc and supports before" do
    items = Array.new(3) { create(:item, channel: @channel) }

    query = "{ unreadItems(first: 2) { id } }"
    post_graphql(query, token: @plain)
    ids = JSON.parse(response.body).dig("data", "unreadItems").map { |i| i["id"] }
    assert_equal [ items[2].id.to_s, items[1].id.to_s ], ids

    query = "{ unreadItems(before: \"#{items[1].id}\") { id } }"
    post_graphql(query, token: @plain)
    ids = JSON.parse(response.body).dig("data", "unreadItems").map { |i| i["id"] }
    assert_equal [ items[0].id.to_s ], ids
  end

  test "unreadItems returns empty when unauthenticated" do
    create(:item, channel: @channel)

    post_graphql("{ unreadItems { id } }")

    body = JSON.parse(response.body)
    assert_equal [], body.dig("data", "unreadItems")
  end

  test "unreadItems with channelGroupId returns items only from groups the user can access" do
    own_group = create(:channel_group, owner: @user)
    own_group.channels << @channel
    item_in_own = create(:item, channel: @channel)

    other_user = create(:user)
    other_group = create(:channel_group, owner: other_user)
    other_channel = create(:channel)
    other_group.channels << other_channel
    create(:item, channel: other_channel)

    query = "{ unreadItems(channelGroupId: \"#{own_group.id}\") { id } }"
    post_graphql(query, token: @plain)
    ids = JSON.parse(response.body).dig("data", "unreadItems").map { |i| i["id"] }
    assert_equal [ item_in_own.id.to_s ], ids

    query = "{ unreadItems(channelGroupId: \"#{other_group.id}\") { id } }"
    post_graphql(query, token: @plain)
    ids = JSON.parse(response.body).dig("data", "unreadItems").map { |i| i["id"] }
    assert_equal [], ids, "他人所有のChannelGroupから記事が取れてはいけない"
  end
end
