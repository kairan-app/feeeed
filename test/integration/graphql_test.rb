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
end
