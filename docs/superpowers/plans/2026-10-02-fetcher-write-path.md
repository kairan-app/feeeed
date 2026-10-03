# fetcher の書き込み経路と worker dyno の廃止 (計画2b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rust の fetcher が Rails の `/fetcher/*` API から貸し出しを受けて新着チェックを行い、結果を Rails が既存のモデルで保存する経路を作る。段階移行のゲートと遅れの監視も入れ、worker dyno を廃止できる状態にする。

**Architecture:** 貸し出し (`channel_leases`) と保存 (`FetchResultApplier`) は Rails に置き、ActiveRecord のバリデーションとコールバックをそのまま使う。fetcher には常駐の `run` サブコマンドを足し、影モードで確かめた取得・整形の処理を使って結果を送る。Rust と Rails の間の JSON の形は、golden のフィクスチャから作った `result` のサンプルを両方のテストで読んで固定する。

**Tech Stack:** Rails 8.1 / Minitest + mocha / FactoryBot / Solid Queue、Rust (tokio, reqwest, serde, wiremock)

**Spec:** `docs/superpowers/specs/2026-10-02-fetcher-write-path-design.md`

## Global Constraints

- 貸し出し・保存は Rails の `/fetcher/*` で行う。dispatcher (`dispatcher/`) には手を入れない (影モード専用として残す)
- 認証は `Authorization: Bearer <token>`。環境変数 `FETCHER_TOKENS` に `{"ワーカー名": "トークンの SHA-256 (16進)"}` の JSON を置き、定数時間で照合する
- 段階移行の割合は環境変数 `ROLLOUT_PERCENT` (既定 0) を Rails にだけ置く。`channel_id % 100 < ROLLOUT_PERCENT` が fetcher の担当
- lease の期限は10分。fetcher の1チャンネルの持ち時間は5分
- entries が200件を超える結果は、item の保存以降を `FetchResultApplyJob` に任せて 202 を返す
- fetcher の本文サイズの上限は 64MB
- fetcher からは Sentry に送らない (構造化ログを標準出力に出すだけ)
- 新しいチャンネルの初回取得 (`after_create_commit` の `mode: :all`)、手動取得、登録時のプレビューは Rails に残す
- Rails のコマンドは `docker compose run --rm web ...` で実行する。Ruby のファイルを編集したら `docker compose run --rm web bundle exec rubocop -c .rubocop.yml` を通す
- Rust は `cd fetcher && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test` を通す
- `rm` は `rm -f` で実行する。`git add` は `-A` を使わず、ファイルを指定する
- リポジトリに残すテキスト (コード・コメント・コミットメッセージ・ドキュメント) に、自宅のマシンの名前など、このプロジェクトの外の固有名詞を書かない。本番の fetcher の置き場所は「自宅の Linux マシン」と書く
- コミットメッセージは日本語で、末尾に `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>` を付ける

### spec からの細かい変更 (計画を書く段階で決めたもの)

1. `guid_lookups` の形は、今の fetcher の `new-guids` 呼び出しに合わせて `{ "entries": [{ "entry_id", "url" }] }` → `{ "new": [bool, ...] }` にする (entry ごとに entry_id と url の両方で判定するため)
2. 同じホストの排他は、`channel_leases.host` の**一意制約**と `INSERT ... ON CONFLICT DO NOTHING` で行う。`FOR UPDATE SKIP LOCKED` はチャンネルの行しか守れず、同時に来た2つの貸し出しが同じホストの別チャンネルを取れてしまうため
3. lease の確認は行ロックではなく、「このワーカーのもので期限内なら `leased_until` を延ばす」1本の UPDATE で行う (`ChannelLease.renew`)。保存の間ロックを持ち続けないため
4. 貸し出しのレスポンスに `proxy_required_domains` (全件) を足す。OGP の取得で proxy を使うかの判定に要る (影モードと同じ)
5. `result` の `register_proxy_domain` (bool) を `register_proxy_urls` (配列) にし、`proxy_used` は送らない。`final_url` はリダイレクトしたときだけ入れる
6. 遅れの監視は、15分ごと + 1時間に1回の間引きではなく、**1時間に1回**の実行にする。間引きの状態を持つ場所 (キャッシュ) が本番に無いため。検知は最大1時間遅れる

## Review Focus

- 同時に2つの `POST /fetcher/leases` が来ても、同じチャンネル・同じホストが二重に貸し出されないこと → Task 2 で「既存の lease と同じホストのチャンネルは選ばれない」と「一意制約でぶつかった行は返さない」をテストする
- `result` が lease の期限切れのあとに届いたとき、何も書かずに 409 を返すこと (別のワーカーが同じチャンネルを処理しているかもしれない) → Task 6 のテスト
- 同じ guid の item が既にある (別の取得と重なった) entry を、Sentry に warning を送らずに黙って飛ばすこと → Task 5 のテスト
- リダイレクト先が既存のチャンネルだったとき、停止して item を保存せず、それでもチェック済みの記録は進むこと → Task 5 のテスト
- fetcher が SIGTERM を受けたとき、処理中の結果を送ってから止まり、新しい貸し出しを受けないこと → Task 13 のテスト

---

## Part 0: #828 の修正 (別の PR)

作業ブランチは main から切った `fix/set-check-interval-update-column`。この Task だけで PR にする。

### Task 1: `set_check_interval!` を `update_column` にする (#828)

**Files:**
- Modify: `app/models/channel.rb` (`set_check_interval!` の最後の `update!`)
- Test: `test/models/channel_fetch_and_save_items_test.rb`

**Interfaces:**
- Produces: `Channel#set_check_interval!` が association のキャッシュに無効な Item が残っていても例外を出さない (Task 5 が使う)

- [ ] **Step 1: 失敗するテストを書く**

`test/models/channel_fetch_and_save_items_test.rb` の `describe "fetch_and_save_items 後の mark_items_checked! (FEEEED-87)"` の直後に足す:

```ruby
  # #828: mark_items_checked! と同じ原因で、set_check_interval! の update! も
  # association キャッシュに残った無効な Item に巻き込まれて "Items is invalid" になる
  describe "fetch_and_save_items 後の set_check_interval! (#828)" do
    test "一部のエントリが保存失敗しても set_check_interval! が成功し、間隔が更新される" do
      @channel.update_column(:check_interval_hours, 24)
      entries = [
        build_mock_entry(entry_id: "good-1", url: "https://example.com/good-1", published: 1.hour.ago, title: "Good 1"),
        build_mock_entry(entry_id: "good-2", url: "https://example.com/good-2", published: 2.days.ago, title: "Good 2"),
        build_mock_entry(entry_id: "good-3", url: "https://example.com/good-3", published: 3.days.ago, title: "Good 3"),
        build_mock_entry(entry_id: "bad-entry", url: "https://example.com/bad", published: nil, title: "Bad Entry")
      ]
      stub_feed_with_entries(entries)
      OpenGraph.stubs(:new).returns(OpenStruct.new(image: nil))
      @channel.stubs(:sleep)

      @channel.fetch_and_save_items(:all)

      assert_nothing_raised do
        @channel.set_check_interval!
      end
      assert_equal 1, @channel.reload.check_interval_hours
    end
  end
```

- [ ] **Step 2: 失敗することを確かめる**

Run: `docker compose run --rm web rails test test/models/channel_fetch_and_save_items_test.rb`
Expected: 追加したテストが `ActiveRecord::RecordInvalid: Validation failed: Items is invalid` で FAIL

- [ ] **Step 3: 直す**

`app/models/channel.rb` の `set_check_interval!` の最後を次にする:

```ruby
    # update! ではなく update_column を使う (mark_items_checked! と同じ理由、#828)。
    # fetch_and_save_items 後に association キャッシュに無効な Item が残っていると、
    # update! が関連レコードのバリデーションを巻き込んで失敗するため。
    update_column(:check_interval_hours, interval)
```

- [ ] **Step 4: 通ることを確かめる**

Run: `docker compose run --rm web rails test test/models/channel_fetch_and_save_items_test.rb test/jobs/channel_items_updater_job_test.rb`
Expected: PASS

Run: `docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/models/channel.rb test/models/channel_fetch_and_save_items_test.rb`
Expected: no offenses

- [ ] **Step 5: コミット**

```bash
git add app/models/channel.rb test/models/channel_fetch_and_save_items_test.rb
git commit -m "set_check_interval!をupdate_columnにし、無効なItemが残っていても間隔を更新する (#828)"
```

---

## Part 1: Rails の API

作業ブランチは `design/fetcher-write-path` (spec と、この plan をコミット済み)。Task 2〜8 で1つの PR にする。`ROLLOUT_PERCENT` の既定は 0 なので、デプロイしても本番の動きは変わらない。

### Task 2: `channel_leases` と貸し出しの選び方

**Files:**
- Create: `db/migrate/20261002120000_create_channel_leases.rb`
- Create: `app/models/channel_lease.rb`
- Create: `app/models/fetcher_rollout.rb`
- Modify: `db/schema.rb` (マイグレーションで更新される)
- Test: `test/models/channel_lease_test.rb`

**Interfaces:**
- Produces:
  - `FetcherRollout.percent -> Integer` (0〜100)、`FetcherRollout.covers?(channel_id) -> Boolean`
  - `ChannelLease.grant!(worker_name:, max:, rollout_percent:, now: Time.current) -> Array<ChannelLease>` (`channel` を includes 済み)
  - `ChannelLease.renew(channel_id:, worker_name:, now: Time.current) -> Boolean`
  - `ChannelLease.release(channel_id:, worker_name:) -> Integer`
  - `ChannelLease::TTL` (10分)、`ChannelLease#host`、`ChannelLease#worker_name`

- [ ] **Step 1: マイグレーションを書いて流す**

`db/migrate/20261002120000_create_channel_leases.rb`:

```ruby
class CreateChannelLeases < ActiveRecord::Migration[8.1]
  def change
    # fetcher (Rust) に貸し出し中のチャンネル。1チャンネル・1ホストにつき同時に1つまで (一意制約で守る)
    create_table :channel_leases, id: false do |t|
      t.references :channel, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :host, null: false
      t.string :worker_name, null: false
      t.datetime :leased_until, null: false
      t.datetime :created_at, null: false
    end
    add_index :channel_leases, :host, unique: true
  end
end
```

Run: `docker compose run --rm web rails db:migrate && docker compose run --rm -e RAILS_ENV=test web rails db:migrate`
Expected: `db/schema.rb` に `create_table "channel_leases", id: false` と2つの一意インデックスが入る

- [ ] **Step 2: 失敗するテストを書く**

`test/models/channel_lease_test.rb`:

```ruby
require "test_helper"

class ChannelLeaseTest < ActiveSupport::TestCase
  def due_channel(host, **attrs)
    create(:channel, feed_url: "https://#{host}/feed.xml", last_items_checked_at: nil, **attrs)
  end

  def grant(max: 8, rollout_percent: 100, worker_name: "w1", now: Time.current)
    ChannelLease.grant!(worker_name:, max:, rollout_percent:, now:)
  end

  test "チェックが必要なチャンネルを貸し出し、lease を登録する" do
    channel = due_channel("a.example.com")

    leases = grant

    assert_equal [ channel.id ], leases.map(&:channel_id)
    lease = leases.first
    assert_equal "a.example.com", lease.host
    assert_equal "w1", lease.worker_name
    assert_in_delta 10.minutes.from_now, lease.leased_until, 5.seconds
    assert_equal channel.feed_url, lease.channel.feed_url
  end

  test "チェックの必要がないチャンネルは貸し出さない" do
    due_channel("a.example.com", last_items_checked_at: 1.minute.ago, check_interval_hours: 1)

    assert_empty grant
  end

  test "停止中のチャンネルは貸し出さない" do
    channel = due_channel("a.example.com")
    ChannelStopper.create!(channel:, reason: "test")

    assert_empty grant
  end

  test "ロールアウトの割合の外のチャンネルは貸し出さない" do
    channel = due_channel("a.example.com")
    percent = channel.id % 100

    assert_empty grant(rollout_percent: percent)
    assert_equal [ channel.id ], grant(rollout_percent: percent + 1).map(&:channel_id)
  end

  test "割合が 0 なら何も貸し出さない" do
    due_channel("a.example.com")

    assert_empty grant(rollout_percent: 0)
  end

  test "同じバッチの中でホストが重ならない" do
    due_channel("a.example.com")
    due_channel("a.example.com")
    due_channel("b.example.com")

    leases = grant

    assert_equal %w[a.example.com b.example.com], leases.map(&:host).sort
  end

  test "lease 中のチャンネルと、lease 中のホストのチャンネルは貸し出さない" do
    first = due_channel("a.example.com")
    due_channel("a.example.com")

    assert_equal [ first.id ], grant.map(&:channel_id)
    assert_empty grant(worker_name: "w2")
  end

  test "ホストは大文字小文字を区別しない" do
    due_channel("A.Example.com")
    due_channel("a.example.COM")

    assert_equal 1, grant.size
  end

  test "期限切れの lease は消して、また貸し出す" do
    channel = due_channel("a.example.com")
    grant(now: 11.minutes.ago)

    leases = grant(worker_name: "w2")

    assert_equal [ channel.id ], leases.map(&:channel_id)
    assert_equal "w2", leases.first.worker_name
  end

  test "max 件までしか貸し出さない" do
    3.times { |i| due_channel("h#{i}.example.com") }

    assert_equal 2, grant(max: 2).size
  end

  test "チェック間隔の短いものから貸し出す" do
    slow = due_channel("slow.example.com", check_interval_hours: 24)
    fast = due_channel("fast.example.com", check_interval_hours: 1)

    assert_equal [ fast.id ], grant(max: 1).map(&:channel_id)
    assert_equal [ slow.id ], grant(max: 1).map(&:channel_id)
  end

  test "一意制約でぶつかった行は返さない" do
    channel = due_channel("a.example.com")
    # 同時に来た別の貸し出しが、選んだあと・登録する前に同じホストを取った状況を作る
    ChannelLease.stubs(:due_channels_one_per_host).returns(
      Channel.select("channels.*, 'a.example.com' AS host").where(id: channel.id).to_a
    )
    ChannelLease.insert_all!([ { channel_id: create(:channel, feed_url: "https://a.example.com/other.xml").id,
                                 host: "a.example.com", worker_name: "w2",
                                 leased_until: 10.minutes.from_now, created_at: Time.current } ])

    assert_empty grant
  end

  describe "renew" do
    test "自分の期限内の lease なら期限を延ばして true を返す" do
      channel = due_channel("a.example.com")
      grant(now: 5.minutes.ago)

      assert ChannelLease.renew(channel_id: channel.id, worker_name: "w1")
      assert_in_delta 10.minutes.from_now, ChannelLease.find(channel.id).leased_until, 5.seconds
    end

    test "他のワーカーの lease なら false" do
      channel = due_channel("a.example.com")
      grant

      assert_not ChannelLease.renew(channel_id: channel.id, worker_name: "w2")
    end

    test "期限切れなら false" do
      channel = due_channel("a.example.com")
      grant(now: 11.minutes.ago)

      assert_not ChannelLease.renew(channel_id: channel.id, worker_name: "w1")
    end
  end

  test "release は自分の lease だけを消す" do
    channel = due_channel("a.example.com")
    grant

    assert_equal 0, ChannelLease.release(channel_id: channel.id, worker_name: "w2")
    assert_equal 1, ChannelLease.release(channel_id: channel.id, worker_name: "w1")
    assert_not ChannelLease.exists?(channel_id: channel.id)
  end

  describe "FetcherRollout" do
    test "ROLLOUT_PERCENT を 0〜100 に丸めて読む" do
      with_env("ROLLOUT_PERCENT" => nil) { assert_equal 0, FetcherRollout.percent }
      with_env("ROLLOUT_PERCENT" => "10") { assert_equal 10, FetcherRollout.percent }
      with_env("ROLLOUT_PERCENT" => "150") { assert_equal 100, FetcherRollout.percent }
      with_env("ROLLOUT_PERCENT" => "-1") { assert_equal 0, FetcherRollout.percent }
    end

    test "covers? は channel_id % 100 が割合未満か" do
      with_env("ROLLOUT_PERCENT" => "10") do
        assert FetcherRollout.covers?(209)
        assert_not FetcherRollout.covers?(210)
      end
    end
  end

  private

  def with_env(vars)
    old = vars.keys.index_with { ENV[_1] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end
end
```

- [ ] **Step 3: 失敗することを確かめる**

Run: `docker compose run --rm web rails test test/models/channel_lease_test.rb`
Expected: `NameError: uninitialized constant ChannelLease` などで FAIL

- [ ] **Step 4: 実装する**

`app/models/fetcher_rollout.rb`:

```ruby
# 新着チェックを fetcher (Rust) へ段階的に移すための割合。channel_id % 100 がこれ未満のチャンネルを fetcher に任せる。
# 0 なら全部 Rails (ChannelItemsUpdaterJob) が取る
module FetcherRollout
  def self.percent
    ENV.fetch("ROLLOUT_PERCENT", "0").to_i.clamp(0, 100)
  end

  def self.covers?(channel_id)
    channel_id % 100 < percent
  end
end
```

`app/models/channel_lease.rb`:

```ruby
# fetcher (Rust) に貸し出し中のチャンネル。同じチャンネルと同じホストは、同時に1つの fetcher にしか貸し出さない
# (channel_id と host の一意制約で守る)。結果が届かないまま TTL を過ぎた lease は、次の貸し出しのときに消す
class ChannelLease < ApplicationRecord
  self.primary_key = :channel_id

  belongs_to :channel

  TTL = 10.minutes
  # feed_url からホストを取り出す式 (dispatcher の selectDueChannels と同じ)
  HOST_SQL = "lower(substring(channels.feed_url from '^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:?#]+)'))".freeze

  class << self
    # チェックが必要なチャンネルを、ホストが重ならないように最大 max 件貸し出す
    def grant!(worker_name:, max:, rollout_percent:, now: Time.current)
      return [] if rollout_percent <= 0

      transaction do
        where(leased_until: ...now).delete_all
        candidates = due_channels_one_per_host(max:, rollout_percent:)
        next [] if candidates.empty?

        rows = candidates.map { |c|
          { channel_id: c.id, host: c.host, worker_name:, leased_until: now + TTL, created_at: now }
        }
        # 同時に来た別の貸し出しと、チャンネルかホストがぶつかった行は一意制約で飛ばす (ON CONFLICT DO NOTHING)
        granted_ids = insert_all(rows, returning: [ :channel_id ]).rows.flatten
        where(channel_id: granted_ids).includes(:channel).to_a
      end
    end

    # lease がこのワーカーのもので期限内なら、期限を今から TTL 延ばして true を返す
    def renew(channel_id:, worker_name:, now: Time.current)
      where(channel_id:, worker_name:).where("leased_until > ?", now).update_all(leased_until: now + TTL) == 1
    end

    def release(channel_id:, worker_name:)
      where(channel_id:, worker_name:).delete_all
    end

    private

    # ホストごとに優先度の一番高いチャンネルを1つずつ選び、その中から優先度順に max 件
    def due_channels_one_per_host(max:, rollout_percent:)
      due = Channel.not_stopped.needs_check_now
        .where("channels.id % 100 < ?", rollout_percent)
        .select(:id, :feed_url, :site_url, :check_interval_hours, :last_items_checked_at)
        .select(Arel.sql("#{HOST_SQL} AS host"))
      # HOST_SQL の正規表現に ? があるので、find_by_sql の配列 (プレースホルダ) 形式は使わない
      Channel.find_by_sql(<<~SQL.squish)
        SELECT * FROM (
          SELECT DISTINCT ON (due.host) due.* FROM (#{due.to_sql}) due
          WHERE due.host IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM channel_leases l WHERE l.channel_id = due.id OR l.host = due.host
            )
          ORDER BY due.host, due.check_interval_hours, due.last_items_checked_at
        ) per_host
        ORDER BY per_host.check_interval_hours, per_host.last_items_checked_at
        LIMIT #{Integer(max)}
      SQL
    end
  end
end
```

- [ ] **Step 5: 通ることを確かめる**

Run: `docker compose run --rm web rails test test/models/channel_lease_test.rb`
Expected: PASS

Run: `docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/models/channel_lease.rb app/models/fetcher_rollout.rb db/migrate/20261002120000_create_channel_leases.rb test/models/channel_lease_test.rb`
Expected: no offenses

- [ ] **Step 6: コミット**

```bash
git add db/migrate/20261002120000_create_channel_leases.rb db/schema.rb app/models/channel_lease.rb app/models/fetcher_rollout.rb test/models/channel_lease_test.rb
git commit -m "fetcherへの貸し出しを管理するchannel_leasesを追加する"
```

### Task 3: fetcher API の認証と `POST /fetcher/leases`

**Files:**
- Create: `app/models/fetcher_token.rb`
- Create: `app/controllers/fetcher/base_controller.rb`
- Create: `app/controllers/fetcher/leases_controller.rb`
- Modify: `config/routes.rb` (`/up` の直後に `namespace :fetcher` を足す)
- Test: `test/integration/fetcher/leases_test.rb`、`test/models/fetcher_token_test.rb`

**Interfaces:**
- Consumes: `ChannelLease.grant!`、`FetcherRollout.percent` (Task 2)
- Produces:
  - `FetcherToken.worker_name_for(token) -> String | nil`
  - `Fetcher::BaseController` (private: `worker_name`、`json_body -> Hash`。JSON でない・Hash でない body は 422)
  - ルート: `POST /fetcher/leases`、`POST /fetcher/leases/:channel_id/result` (Task 6)、`POST /fetcher/channels/:channel_id/guid_lookups` (Task 4)
  - テスト用ヘルパー `FetcherApiTestHelper` (`fetcher_headers(token = "secret-token")`、`with_fetcher_tokens { }`)

- [ ] **Step 1: 失敗するテストを書く**

`test/models/fetcher_token_test.rb`:

```ruby
require "test_helper"

class FetcherTokenTest < ActiveSupport::TestCase
  setup do
    @old = ENV["FETCHER_TOKENS"]
    ENV["FETCHER_TOKENS"] = { "w1" => Digest::SHA256.hexdigest("secret-1") }.to_json
  end

  teardown { ENV["FETCHER_TOKENS"] = @old }

  test "トークンの SHA-256 が一致するワーカー名を返す" do
    assert_equal "w1", FetcherToken.worker_name_for("secret-1")
  end

  test "一致しない・空のトークンは nil" do
    assert_nil FetcherToken.worker_name_for("secret-2")
    assert_nil FetcherToken.worker_name_for("")
    assert_nil FetcherToken.worker_name_for(nil)
  end

  test "FETCHER_TOKENS が壊れていたら誰も通さない" do
    ENV["FETCHER_TOKENS"] = "{not json"
    assert_nil FetcherToken.worker_name_for("secret-1")
  end
end
```

`test/test_helper.rb` の末尾に足す:

```ruby
# fetcher (Rust) 向け API のテスト用
module FetcherApiTestHelper
  def with_fetcher_tokens(tokens = { "w1" => "secret-token" })
    old = ENV["FETCHER_TOKENS"]
    ENV["FETCHER_TOKENS"] = tokens.transform_values { Digest::SHA256.hexdigest(_1) }.to_json
    yield
  ensure
    ENV["FETCHER_TOKENS"] = old
  end

  def fetcher_headers(token = "secret-token")
    { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
  end
end
```

`test/integration/fetcher/leases_test.rb`:

```ruby
require "test_helper"

class Fetcher::LeasesTest < ActionDispatch::IntegrationTest
  include FetcherApiTestHelper

  around do |test|
    with_fetcher_tokens { test.call }
  end

  setup do
    @old_rollout = ENV["ROLLOUT_PERCENT"]
    ENV["ROLLOUT_PERCENT"] = "100"
  end

  teardown { ENV["ROLLOUT_PERCENT"] = @old_rollout }

  test "トークンが無い・違うと 401" do
    post "/fetcher/leases", params: { max: 1 }.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized

    post "/fetcher/leases", params: { max: 1 }.to_json, headers: fetcher_headers("wrong")
    assert_response :unauthorized
  end

  test "貸し出したチャンネルと proxy の要るドメインを返す" do
    channel = create(:channel, feed_url: "https://a.example.com/feed.xml", site_url: "https://a.example.com/", last_items_checked_at: nil)
    ProxyRequiredDomain.create!(domain: "A.Example.com")

    post "/fetcher/leases", params: { max: 8 }.to_json, headers: fetcher_headers

    assert_response :ok
    body = response.parsed_body
    assert_equal [ { "channel_id" => channel.id, "feed_url" => channel.feed_url,
                     "site_url" => "https://a.example.com/", "use_proxy" => true } ], body["leases"]
    assert_equal [ "a.example.com" ], body["proxy_required_domains"]
    assert_equal "w1", ChannelLease.find(channel.id).worker_name
  end

  test "ROLLOUT_PERCENT が 0 なら空" do
    ENV["ROLLOUT_PERCENT"] = "0"
    create(:channel, feed_url: "https://a.example.com/feed.xml", last_items_checked_at: nil)

    post "/fetcher/leases", params: { max: 8 }.to_json, headers: fetcher_headers

    assert_response :ok
    assert_empty response.parsed_body["leases"]
  end

  test "max が範囲外・JSON でない body は 422" do
    post "/fetcher/leases", params: { max: 0 }.to_json, headers: fetcher_headers
    assert_response :unprocessable_content

    post "/fetcher/leases", params: { max: 33 }.to_json, headers: fetcher_headers
    assert_response :unprocessable_content

    post "/fetcher/leases", params: "not json", headers: fetcher_headers
    assert_response :unprocessable_content

    post "/fetcher/leases", params: [ 1 ].to_json, headers: fetcher_headers
    assert_response :unprocessable_content
  end
end
```

- [ ] **Step 2: 失敗することを確かめる**

Run: `docker compose run --rm web rails test test/models/fetcher_token_test.rb test/integration/fetcher/leases_test.rb`
Expected: `uninitialized constant FetcherToken` やルーティングエラーで FAIL

- [ ] **Step 3: 実装する**

`app/models/fetcher_token.rb`:

```ruby
# fetcher (Rust) のトークンを照合する。トークンはマシンごとに発行し、環境変数 FETCHER_TOKENS に
# {"ワーカー名": "トークンの SHA-256 (16進)"} の JSON で置く (平文のトークンはサーバに置かない)
module FetcherToken
  def self.worker_name_for(token)
    return nil if token.blank?

    digest = Digest::SHA256.hexdigest(token)
    table.find { |_name, expected| ActiveSupport::SecurityUtils.secure_compare(expected.to_s.downcase, digest) }&.first
  end

  def self.table
    parsed = JSON.parse(ENV.fetch("FETCHER_TOKENS", "{}"))
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    Rails.logger.error "[FetcherToken] FETCHER_TOKENS is not valid JSON"
    {}
  end
end
```

`app/controllers/fetcher/base_controller.rb`:

```ruby
# fetcher (Rust) 向けの API。セッションや CSRF は使わず、マシンごとのトークンで認証する
class Fetcher::BaseController < ActionController::API
  class InvalidBody < StandardError; end

  before_action :authenticate_worker!

  rescue_from InvalidBody, JSON::ParserError do
    head :unprocessable_content
  end

  private

  attr_reader :worker_name

  def authenticate_worker!
    token = request.headers["Authorization"].to_s.delete_prefix("Bearer ")
    @worker_name = FetcherToken.worker_name_for(token)
    head :unauthorized if @worker_name.nil?
  end

  def json_body
    @json_body ||= JSON.parse(request.raw_post).tap { raise InvalidBody unless _1.is_a?(Hash) }
  end
end
```

`app/controllers/fetcher/leases_controller.rb`:

```ruby
class Fetcher::LeasesController < Fetcher::BaseController
  MAX_PER_REQUEST = 32

  def create
    max = json_body["max"]
    raise InvalidBody unless max.is_a?(Integer) && max.between?(1, MAX_PER_REQUEST)

    leases = ChannelLease.grant!(worker_name:, max:, rollout_percent: FetcherRollout.percent)
    proxy_domains = ProxyRequiredDomain.pluck(:domain).map(&:downcase).uniq.sort

    render json: {
      leases: leases.map { |lease|
        { channel_id: lease.channel_id, feed_url: lease.channel.feed_url,
          site_url: lease.channel.site_url, use_proxy: proxy_domains.include?(lease.host) }
      },
      proxy_required_domains: proxy_domains
    }
  end
end
```

`config/routes.rb` の `get "/up" ...` の行の直後に足す:

```ruby
  namespace :fetcher do
    post "leases",                               to: "leases#create"
    post "leases/:channel_id/result",            to: "results#create"
    post "channels/:channel_id/guid_lookups",    to: "guid_lookups#create"
  end
```

- [ ] **Step 4: 通ることを確かめる**

Run: `docker compose run --rm web rails test test/models/fetcher_token_test.rb test/integration/fetcher/leases_test.rb`
Expected: PASS

Run: `docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/models/fetcher_token.rb app/controllers/fetcher config/routes.rb test/test_helper.rb test/models/fetcher_token_test.rb test/integration/fetcher`
Expected: no offenses

- [ ] **Step 5: コミット**

```bash
git add app/models/fetcher_token.rb app/controllers/fetcher/base_controller.rb app/controllers/fetcher/leases_controller.rb config/routes.rb test/test_helper.rb test/models/fetcher_token_test.rb test/integration/fetcher/leases_test.rb
git commit -m "fetcher向けAPIの認証と、チャンネルを貸し出すPOST /fetcher/leasesを追加する"
```

### Task 4: `POST /fetcher/channels/:channel_id/guid_lookups`

**Files:**
- Create: `app/controllers/fetcher/guid_lookups_controller.rb`
- Test: `test/integration/fetcher/guid_lookups_test.rb`

**Interfaces:**
- Consumes: `Fetcher::BaseController`、ルート (Task 3)
- Produces: `{ "entries": [{ "entry_id": String|null, "url": String|null }] }` → `{ "new": [Boolean] }` (entry の順番どおり)。entry_id と url のどちらも、そのチャンネルの `items.guid` に無ければ true

- [ ] **Step 1: 失敗するテストを書く**

`test/integration/fetcher/guid_lookups_test.rb`:

```ruby
require "test_helper"

class Fetcher::GuidLookupsTest < ActionDispatch::IntegrationTest
  include FetcherApiTestHelper

  around do |test|
    with_fetcher_tokens { test.call }
  end

  setup do
    @channel = create(:channel)
    create(:item, channel: @channel, guid: "by-entry-id")
    create(:item, channel: @channel, guid: "https://example.com/by-url")
    create(:item, guid: "other-channel")
  end

  test "entry_id と url のどちらも保存済みでないものだけ true" do
    entries = [
      { entry_id: "by-entry-id", url: "https://example.com/x" },
      { entry_id: nil, url: "https://example.com/by-url" },
      { entry_id: "new-one", url: "https://example.com/by-url" },
      { entry_id: "other-channel", url: nil },
      { entry_id: "new-two", url: "https://example.com/new" }
    ]

    post "/fetcher/channels/#{@channel.id}/guid_lookups", params: { entries: }.to_json, headers: fetcher_headers

    assert_response :ok
    assert_equal [ false, false, false, true, true ], response.parsed_body["new"]
  end

  test "空の entries には空を返す" do
    post "/fetcher/channels/#{@channel.id}/guid_lookups", params: { entries: [] }.to_json, headers: fetcher_headers

    assert_response :ok
    assert_equal [], response.parsed_body["new"]
  end

  test "entries の形が不正なら 422" do
    post "/fetcher/channels/#{@channel.id}/guid_lookups", params: { entries: "x" }.to_json, headers: fetcher_headers
    assert_response :unprocessable_content

    post "/fetcher/channels/#{@channel.id}/guid_lookups", params: { entries: [ "x" ] }.to_json, headers: fetcher_headers
    assert_response :unprocessable_content
  end
end
```

- [ ] **Step 2: 失敗することを確かめる**

Run: `docker compose run --rm web rails test test/integration/fetcher/guid_lookups_test.rb`
Expected: `uninitialized constant Fetcher::GuidLookupsController` で FAIL

- [ ] **Step 3: 実装する**

`app/controllers/fetcher/guid_lookups_controller.rb`:

```ruby
# フィードの entry のうち、まだ保存していないものを判定する (ChannelItemsUpdaterJob の only_non_existing と同じ判定)。
#
# 読み取りだけで冪等な照会なので、意味としては GET が合う。ただ entry は1フィードで数千件・数百KBになり、URL に載せられない。
# 本来は RFC 10008 の QUERY メソッドが合うが、2026-10 時点で Puma 8.0.2 は QUERY を 501 で拒否し、
# Rails 8.1 もメソッドとして知らない (Cloudflare と Heroku のルーターは通す)。
# そのため POST で body に載せる。Puma と Rails が QUERY に対応したら移す候補
class Fetcher::GuidLookupsController < Fetcher::BaseController
  MAX_ENTRIES = 5_000
  SLICE = 1_000

  def create
    entries = json_body["entries"]
    raise InvalidBody unless entries.is_a?(Array) && entries.size <= MAX_ENTRIES && entries.all?(Hash)

    channel_id = params[:channel_id].to_i
    keys = entries.flat_map { [ _1["entry_id"], _1["url"] ] }.compact.uniq
    existing = keys.each_slice(SLICE).flat_map { Item.where(channel_id:, guid: _1).pluck(:guid) }.to_set

    render json: { new: entries.map { !existing.include?(_1["entry_id"]) && !existing.include?(_1["url"]) } }
  end
end
```

- [ ] **Step 4: 通ることを確かめる**

Run: `docker compose run --rm web rails test test/integration/fetcher/guid_lookups_test.rb`
Expected: PASS

Run: `docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/controllers/fetcher/guid_lookups_controller.rb test/integration/fetcher/guid_lookups_test.rb`
Expected: no offenses

- [ ] **Step 5: コミット**

```bash
git add app/controllers/fetcher/guid_lookups_controller.rb test/integration/fetcher/guid_lookups_test.rb
git commit -m "まだ保存していないentryを判定するPOST /fetcher/channels/:id/guid_lookupsを追加する"
```

### Task 5: `FetchResultApplier` (結果の保存)

**Files:**
- Create: `app/services/fetch_result_applier.rb`
- Test: `test/services/fetch_result_applier_test.rb`

**Interfaces:**
- Consumes: `Channel#mark_items_checked!`、`Channel#set_check_interval!` (Task 1 で update_column 化済み)、`Channel#adjust_schedules!`、`ProxyRequiredDomain.register!`、`ItemCreationNotifierJob`
- Produces:
  - `FetchResultApplier::ITEMS_IN_REQUEST_LIMIT` (200)
  - `FetchResultApplier.valid_payload?(payload) -> Boolean`
  - `FetchResultApplier.new(channel:)`
  - `#apply_channel!(payload) -> Boolean` (item の保存に進んでよいか。取得失敗・リダイレクト先が既存で停止・リダイレクト処理の例外なら false)
  - `#save_items!(entries, latest_guids:) -> { created: Integer, skipped: Integer }`
  - `#finish!` (チェック済みの記録と再計算)
- payload は JSON をパースした Hash (文字列キー)。形は spec 節4 の `result` に、本 plan の「spec からの細かい変更」5 を当てたもの

- [ ] **Step 1: 失敗するテストを書く**

`test/services/fetch_result_applier_test.rb`:

```ruby
require "test_helper"

class FetchResultApplierTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @channel = create(:channel, title: "Old Title", feed_url: "https://a.example.com/feed.xml",
                                site_url: "https://a.example.com/", check_interval_hours: 24,
                                last_items_checked_at: 1.day.ago)
    @applier = FetchResultApplier.new(channel: @channel)
    Sentry.stubs(:capture_message)
    Sentry.stubs(:capture_exception)
  end

  def entry(guid, published_at: "2026-09-25T00:00:00Z", **attrs)
    { "guid" => guid, "title" => "Title #{guid}", "url" => "https://a.example.com/#{guid}",
      "image_url" => nil, "published_at" => published_at,
      "data" => { "entry_id" => guid, "summary" => "S #{guid}" } }.merge(attrs.stringify_keys)
  end

  def payload(**overrides)
    { "fetched" => true, "error" => nil, "final_url" => nil, "register_proxy_urls" => [],
      "channel" => { "title" => "New Title", "description" => "D", "site_url" => "https://a.example.com/",
                     "image_url" => nil, "applied_filters" => [], "filter_details" => {} },
      "entries" => [], "latest_guids" => [] }.merge(overrides.stringify_keys)
  end

  describe "valid_payload?" do
    test "最低限の形を確かめる" do
      assert FetchResultApplier.valid_payload?(payload)
      assert FetchResultApplier.valid_payload?({ "fetched" => false, "error" => { "kind" => "timeout", "message" => "x" } })
      assert_not FetchResultApplier.valid_payload?({ "fetched" => "yes" })
      assert_not FetchResultApplier.valid_payload?(payload(entries: "x"))
      assert_not FetchResultApplier.valid_payload?(payload(entries: [ "x" ]))
      assert_not FetchResultApplier.valid_payload?(payload(channel: "x"))
      assert_not FetchResultApplier.valid_payload?(payload(latest_guids: nil))
    end
  end

  describe "apply_channel!" do
    test "チャンネル情報を更新し、item の保存に進む" do
      assert @applier.apply_channel!(payload)
      assert_equal "New Title", @channel.reload.title
      assert_equal "D", @channel.description
    end

    test "channel が null なら更新しない" do
      assert @applier.apply_channel!(payload(channel: nil))
      assert_equal "Old Title", @channel.reload.title
    end

    test "バリデーションに通らないチャンネル情報は更新せずに進む" do
      assert @applier.apply_channel!(payload(channel: payload["channel"].merge("title" => "")))
      assert_equal "Old Title", @channel.reload.title
    end

    test "取得に失敗していたら何も更新せず、item の保存にも進まない" do
      assert_not @applier.apply_channel!({ "fetched" => false, "error" => { "kind" => "timeout", "message" => "t" } })
      assert_equal "Old Title", @channel.reload.title
    end

    test "リダイレクトしていたら feed_url を更新する" do
      assert @applier.apply_channel!(payload(final_url: "https://a.example.com/new.xml"))
      assert_equal "https://a.example.com/new.xml", @channel.reload.feed_url
    end

    test "リダイレクト先が既存のチャンネルなら停止し、item の保存に進まない" do
      existing = create(:channel, feed_url: "https://a.example.com/new.xml")

      assert_not @applier.apply_channel!(payload(final_url: "https://a.example.com/new.xml"))
      assert_equal "https://a.example.com/feed.xml", @channel.reload.feed_url
      assert_equal "Old Title", @channel.title
      assert_match "##{existing.id}", @channel.stopper.reason
    end

    test "register_proxy_urls のホストを proxy の要るドメインに登録する" do
      @applier.apply_channel!(payload(register_proxy_urls: [ "https://blocked.example.com/feed.xml" ]))
      assert ProxyRequiredDomain.exists?(domain: "blocked.example.com")
    end
  end

  describe "save_items!" do
    test "entries を保存し、latest_guids に含まれるものだけ通知する" do
      result = nil
      assert_enqueued_jobs 1, only: ItemCreationNotifierJob do
        result = @applier.save_items!([ entry("g1"), entry("g2") ], latest_guids: [ "g2", "https://a.example.com/g2" ])
      end

      assert_equal({ created: 2, skipped: 0 }, result)
      item = @channel.items.find_by!(guid: "g1")
      assert_equal "Title g1", item.title
      assert_equal Time.utc(2026, 9, 25), item.published_at
      assert_equal "S g1", item.data["summary"]
    end

    test "既に同じ guid の item があれば、Sentry に送らずに飛ばす" do
      create(:item, channel: @channel, guid: "g1")
      Sentry.expects(:capture_message).never

      result = @applier.save_items!([ entry("g1") ], latest_guids: [ "g1" ])

      assert_equal({ created: 0, skipped: 1 }, result)
    end

    test "バリデーションに落ちた entry は Sentry に warning を送って飛ばし、残りは保存する" do
      Sentry.expects(:capture_message).with(regexp_matches(/validation failed/), has_entry(level: :warning)).once

      result = @applier.save_items!([ entry("bad", published_at: nil), entry("good") ], latest_guids: [])

      assert_equal({ created: 1, skipped: 1 }, result)
      assert @channel.items.exists?(guid: "good")
    end

    test "association のキャッシュに無効な Item を残さない (#828)" do
      @applier.save_items!([ entry("bad", published_at: nil) ], latest_guids: [])

      assert_nothing_raised { @channel.update!(title: "Still Valid") }
    end
  end

  describe "finish!" do
    test "チェック済みを記録し、間隔とスケジュールを計算し直す" do
      @applier.save_items!([ entry("g1", published_at: 1.hour.ago.iso8601), entry("g2", published_at: 2.days.ago.iso8601),
                             entry("g3", published_at: 3.days.ago.iso8601) ], latest_guids: [])

      @applier.finish!

      @channel.reload
      assert_operator @channel.last_items_checked_at, :>, 1.minute.ago
      assert_equal 1, @channel.check_interval_hours
    end

    test "1つの手順が失敗しても残りの手順は進む" do
      @channel.stubs(:set_check_interval!).raises(RuntimeError, "boom")
      @channel.expects(:adjust_schedules!).once
      Sentry.expects(:capture_exception).once

      @applier.finish!

      assert_operator @channel.reload.last_items_checked_at, :>, 1.minute.ago
    end
  end
end
```

- [ ] **Step 2: 失敗することを確かめる**

Run: `docker compose run --rm web rails test test/services/fetch_result_applier_test.rb`
Expected: `uninitialized constant FetchResultApplier` で FAIL

- [ ] **Step 3: 実装する**

`app/services/fetch_result_applier.rb`:

```ruby
# fetcher (Rust) が送ってきた取得結果を保存する。ChannelItemsUpdaterJob と同じ順番で、
# リダイレクト → チャンネル情報 → item → チェック済みの記録と再計算 を行う。
# 各手順の例外は Sentry に送って次の手順に進む (ジョブの handle_error と同じ考え方)。
# fetcher の整形済みの値をそのまま信じず、保存は ActiveRecord のバリデーションとコールバックを通す
class FetchResultApplier
  # これより多い entries は、リクエストの中では保存せず FetchResultApplyJob に任せる (Heroku のルーターは30秒で打ち切る)
  ITEMS_IN_REQUEST_LIMIT = 200
  CHANNEL_ATTRIBUTES = %w[title description site_url image_url applied_filters filter_details].freeze

  def self.valid_payload?(payload)
    return false unless payload.is_a?(Hash) && [ true, false ].include?(payload["fetched"])
    return true unless payload["fetched"]

    payload["entries"].is_a?(Array) && payload["entries"].all?(Hash) &&
      payload["latest_guids"].is_a?(Array) &&
      (payload["channel"].nil? || payload["channel"].is_a?(Hash)) &&
      (payload["register_proxy_urls"].nil? || payload["register_proxy_urls"].is_a?(Array))
  end

  def initialize(channel:)
    @channel = channel
  end

  # 取得失敗・リダイレクトの処理を行い、item の保存に進んでよいかを返す
  def apply_channel!(payload)
    unless payload["fetched"]
      error = payload["error"] || {}
      Rails.logger.info "[FetchResultApplier] Channel #{@channel.id} fetch failed - #{error['kind']}: #{error['message']}"
      return false
    end

    step("Failed to register proxy domain") { Array(payload["register_proxy_urls"]).each { ProxyRequiredDomain.register!(_1) } }
    # リダイレクトの処理で例外が出たら、今の fetch_and_save_items と同じく item は保存しない
    return false unless step("Failed to follow redirect") { follow_redirect(payload["final_url"]) } == :ok

    step("Failed to update channel info") { update_info(payload["channel"]) }
    true
  end

  def save_items!(entries, latest_guids:)
    notifiable = latest_guids.to_set
    counts = { created: 0, skipped: 0 }

    entries.each do |entry|
      # channel.items を通さない。無効な Item が association のキャッシュに残らないようにする (#828)
      item = Item.new(
        channel_id: @channel.id, guid: entry["guid"], title: entry["title"], url: entry["url"],
        image_url: entry["image_url"], published_at: entry["published_at"], data: entry["data"]
      )
      if item.save
        counts[:created] += 1
        ItemCreationNotifierJob.perform_later(item.id) if notifiable.include?(item.guid)
      else
        counts[:skipped] += 1
        # 同じ guid が既に保存されている (別の取得と重なった) のはデータの問題ではないので知らせない
        report_invalid(entry, item) unless item.errors.of_kind?(:guid, :taken)
      end
    rescue ActiveRecord::RecordNotUnique
      counts[:skipped] += 1
    rescue StandardError => e
      counts[:skipped] += 1
      Sentry.capture_exception(e, extra: { channel_id: @channel.id, channel_title: @channel.title,
                                           item_title: entry["title"], item_guid: entry["guid"] })
    end

    counts
  end

  def finish!
    step("Failed to mark items checked") { @channel.mark_items_checked! }
    step("Failed to set check interval") { @channel.set_check_interval! }
    step("Failed to adjust schedules") { @channel.adjust_schedules! }
  end

  private

  def follow_redirect(final_url)
    return :ok if final_url.blank? || final_url == @channel.feed_url

    Rails.logger.info "[FetchResultApplier] Detected redirect from #{@channel.feed_url} to #{final_url}, updating channel ##{@channel.id}"
    @channel.update!(feed_url: final_url)
    :ok
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.errors.of_kind?(:feed_url, :taken)

    @channel.reload
    existing = Channel.find_by(feed_url: final_url)
    Rails.logger.warn "[FetchResultApplier] Redirect target #{final_url} already exists as channel ##{existing&.id}, stopping channel ##{@channel.id}"
    ChannelStopper.find_or_create_by!(channel: @channel) do |stopper|
      stopper.reason = "Redirect target #{final_url} already exists as channel ##{existing&.id}"
    end
    :stopped
  end

  # Channel.save_from と同じく bang なしで更新する (バリデーションに落ちたら更新せずに進む)。
  # 重要な項目が変われば notify_channel_change (after_commit) が Discord に知らせる
  def update_info(attributes)
    return if attributes.nil?

    @channel.update(attributes.slice(*CHANNEL_ATTRIBUTES))
  end

  def report_invalid(entry, item)
    messages = item.errors.full_messages.join(", ")
    Sentry.capture_message(
      "Skipped entry: validation failed - #{messages}",
      level: :warning,
      extra: { channel_id: @channel.id, channel_title: @channel.title, item_title: entry["title"],
               item_guid: entry["guid"], skip_reason: "validation_failed", validation_errors: messages }
    )
    Rails.logger.warn "[FetchResultApplier] Skipped item (validation) - Channel: #{@channel.id}, Item: #{entry['title']} - #{messages}"
  end

  # ブロックの値を返す。例外なら Sentry に送って :failed を返す
  def step(context)
    yield
  rescue StandardError => e
    Sentry.capture_exception(e, extra: { channel_id: @channel.id, channel_title: @channel.title,
                                         feed_url: @channel.feed_url, context: })
    message = e.message.dup.force_encoding(Encoding::UTF_8).scrub
    Rails.logger.error "[FetchResultApplier] #{context} - Channel: #{@channel.id} - Error: #{e.class.name}: #{message}"
    :failed
  end
end
```

- [ ] **Step 4: 通ることを確かめる**

Run: `docker compose run --rm web rails test test/services/fetch_result_applier_test.rb`
Expected: PASS

Run: `docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/services/fetch_result_applier.rb test/services/fetch_result_applier_test.rb`
Expected: no offenses

- [ ] **Step 5: コミット**

```bash
git add app/services/fetch_result_applier.rb test/services/fetch_result_applier_test.rb
git commit -m "fetcherの取得結果をモデルを通して保存するFetchResultApplierを追加する"
```

### Task 6: `POST /fetcher/leases/:channel_id/result` と `FetchResultApplyJob`

**Files:**
- Create: `app/controllers/fetcher/results_controller.rb`
- Create: `app/jobs/fetch_result_apply_job.rb`
- Test: `test/integration/fetcher/results_test.rb`、`test/jobs/fetch_result_apply_job_test.rb`

**Interfaces:**
- Consumes: `ChannelLease.renew` / `.release` / `.grant!` (Task 2)、`FetchResultApplier` (Task 5)、`Fetcher::BaseController` とルート (Task 3)
- Produces:
  - レスポンス: 200 `{ "created": n, "skipped": n }` / 202 `{ "queued": n }` / 409 (lease を持っていない・期限切れ。何も書かない) / 422 (形が不正)
  - `FetchResultApplyJob.perform_later(channel_id:, worker_name:, entries:, latest_guids:)`

- [ ] **Step 1: 失敗するテストを書く**

`test/integration/fetcher/results_test.rb`:

```ruby
require "test_helper"

class Fetcher::ResultsTest < ActionDispatch::IntegrationTest
  include FetcherApiTestHelper
  include ActiveJob::TestHelper

  around do |test|
    with_fetcher_tokens({ "w1" => "secret-token", "w2" => "other-token" }) { test.call }
  end

  setup do
    @channel = create(:channel, feed_url: "https://a.example.com/feed.xml", last_items_checked_at: nil)
    ChannelLease.grant!(worker_name: "w1", max: 1, rollout_percent: 100)
    Sentry.stubs(:capture_message)
  end

  def entry(guid)
    { guid:, title: "T #{guid}", url: "https://a.example.com/#{guid}", image_url: nil,
      published_at: "2026-09-25T00:00:00Z", data: { entry_id: guid } }
  end

  def post_result(body, token: "secret-token", channel_id: @channel.id)
    post "/fetcher/leases/#{channel_id}/result", params: body.to_json, headers: fetcher_headers(token)
  end

  def ok_body(entries)
    { fetched: true, error: nil, final_url: nil, register_proxy_urls: [], channel: nil,
      entries:, latest_guids: [] }
  end

  test "保存して件数を返し、lease を消してチェック済みにする" do
    post_result(ok_body([ entry("g1"), entry("g2") ]))

    assert_response :ok
    assert_equal({ "created" => 2, "skipped" => 0 }, response.parsed_body)
    assert_equal 2, @channel.items.count
    assert_not ChannelLease.exists?(channel_id: @channel.id)
    assert_not_nil @channel.reload.last_items_checked_at
  end

  test "取得に失敗した結果でもチェック済みにして lease を消す" do
    post_result({ fetched: false, error: { kind: "timeout", message: "timeout" } })

    assert_response :ok
    assert_not_nil @channel.reload.last_items_checked_at
    assert_not ChannelLease.exists?(channel_id: @channel.id)
  end

  test "他のワーカーの lease なら 409 で何も書かない" do
    post_result(ok_body([ entry("g1") ]), token: "other-token")

    assert_response :conflict
    assert_equal 0, @channel.items.count
    assert_nil @channel.reload.last_items_checked_at
    assert ChannelLease.exists?(channel_id: @channel.id)
  end

  test "期限切れの lease なら 409 で何も書かない" do
    ChannelLease.where(channel_id: @channel.id).update_all(leased_until: 1.minute.ago)

    post_result(ok_body([ entry("g1") ]))

    assert_response :conflict
    assert_equal 0, @channel.items.count
  end

  test "形が不正なら 422" do
    post_result({ fetched: "yes" })

    assert_response :unprocessable_content
  end

  test "entries が多ければ item の保存以降をジョブに回して 202 を返し、lease は残す" do
    entries = (1..201).map { entry("g#{_1}") }

    assert_enqueued_with(job: FetchResultApplyJob) do
      post_result(ok_body(entries))
    end

    assert_response :accepted
    assert_equal({ "queued" => 201 }, response.parsed_body)
    assert_equal 0, @channel.items.count
    assert ChannelLease.exists?(channel_id: @channel.id)
  end
end
```

`test/jobs/fetch_result_apply_job_test.rb`:

```ruby
require "test_helper"

class FetchResultApplyJobTest < ActiveJob::TestCase
  setup do
    @channel = create(:channel, feed_url: "https://a.example.com/feed.xml", last_items_checked_at: nil)
    ChannelLease.grant!(worker_name: "w1", max: 1, rollout_percent: 100)
    @entries = [ { "guid" => "g1", "title" => "T", "url" => "https://a.example.com/g1", "image_url" => nil,
                   "published_at" => "2026-09-25T00:00:00Z", "data" => {} } ]
  end

  test "item を保存してチェック済みにし、lease を消す" do
    FetchResultApplyJob.perform_now(channel_id: @channel.id, worker_name: "w1", entries: @entries, latest_guids: [])

    assert @channel.items.exists?(guid: "g1")
    assert_not_nil @channel.reload.last_items_checked_at
    assert_not ChannelLease.exists?(channel_id: @channel.id)
  end

  test "lease が切れていたら何もしない (別のワーカーが処理しているかもしれない)" do
    ChannelLease.where(channel_id: @channel.id).update_all(leased_until: 1.minute.ago)

    FetchResultApplyJob.perform_now(channel_id: @channel.id, worker_name: "w1", entries: @entries, latest_guids: [])

    assert_not @channel.items.exists?(guid: "g1")
    assert_nil @channel.reload.last_items_checked_at
  end
end
```

- [ ] **Step 2: 失敗することを確かめる**

Run: `docker compose run --rm web rails test test/integration/fetcher/results_test.rb test/jobs/fetch_result_apply_job_test.rb`
Expected: `uninitialized constant` で FAIL

- [ ] **Step 3: 実装する**

`app/controllers/fetcher/results_controller.rb`:

```ruby
# fetcher (Rust) から取得結果を受け取って保存する。lease を持っていない・期限切れなら 409 を返し、何も書かない
class Fetcher::ResultsController < Fetcher::BaseController
  def create
    payload = json_body
    raise InvalidBody unless FetchResultApplier.valid_payload?(payload)

    channel_id = params[:channel_id].to_i
    return head :conflict unless ChannelLease.renew(channel_id:, worker_name:)

    applier = FetchResultApplier.new(channel: Channel.find(channel_id))
    entries = applier.apply_channel!(payload) ? payload["entries"] : []

    if entries.size > FetchResultApplier::ITEMS_IN_REQUEST_LIMIT
      # lease は FetchResultApplyJob が終わるまで残し、その間に同じチャンネルを貸し出さない
      FetchResultApplyJob.perform_later(channel_id:, worker_name:, entries:, latest_guids: payload["latest_guids"])
      return render json: { queued: entries.size }, status: :accepted
    end

    counts = applier.save_items!(entries, latest_guids: Array(payload["latest_guids"]))
    applier.finish!
    ChannelLease.release(channel_id:, worker_name:)
    render json: counts
  end
end
```

`app/jobs/fetch_result_apply_job.rb`:

```ruby
# entries の多い取得結果の item の保存以降を行う (Fetcher::ResultsController から回ってくる)
class FetchResultApplyJob < ApplicationJob
  queue_as :default

  def perform(channel_id:, worker_name:, entries:, latest_guids:)
    # 待っている間に lease が切れていたら、別のワーカーが同じチャンネルを処理しているかもしれないので何もしない。
    # 保存しなかった entry は、次の取得で新しいものとしてまた送られてくる
    return unless ChannelLease.renew(channel_id:, worker_name:)

    applier = FetchResultApplier.new(channel: Channel.find(channel_id))
    applier.save_items!(entries, latest_guids:)
    applier.finish!
  ensure
    ChannelLease.release(channel_id:, worker_name:)
  end
end
```

- [ ] **Step 4: 通ることを確かめる**

Run: `docker compose run --rm web rails test test/integration/fetcher test/jobs/fetch_result_apply_job_test.rb`
Expected: PASS

Run: `docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/controllers/fetcher/results_controller.rb app/jobs/fetch_result_apply_job.rb test/integration/fetcher/results_test.rb test/jobs/fetch_result_apply_job_test.rb`
Expected: no offenses

- [ ] **Step 5: コミット**

```bash
git add app/controllers/fetcher/results_controller.rb app/jobs/fetch_result_apply_job.rb test/integration/fetcher/results_test.rb test/jobs/fetch_result_apply_job_test.rb
git commit -m "fetcherの取得結果を受け取るPOST /fetcher/leases/:channel_id/resultを追加する"
```

### Task 7: `ChannelItemsFetcherJob` がロールアウトの対象外だけを積む

**Files:**
- Modify: `app/models/channel.rb` (`self.fetch_and_save_items`)
- Test: `test/models/channel_rollout_test.rb`

**Interfaces:**
- Consumes: `FetcherRollout.percent` (Task 2)

- [ ] **Step 1: 失敗するテストを書く**

`test/models/channel_rollout_test.rb`:

```ruby
require "test_helper"

class ChannelRolloutTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @old = ENV["ROLLOUT_PERCENT"]
    @channel = create(:channel, last_items_checked_at: nil)
    clear_enqueued_jobs
  end

  teardown { ENV["ROLLOUT_PERCENT"] = @old }

  test "ロールアウトの対象のチャンネルはジョブに積まない" do
    ENV["ROLLOUT_PERCENT"] = (@channel.id % 100 + 1).to_s

    assert_no_enqueued_jobs(only: ChannelItemsUpdaterJob) { Channel.fetch_and_save_items }
  end

  test "対象外のチャンネルは今までどおり積む" do
    ENV["ROLLOUT_PERCENT"] = (@channel.id % 100).to_s

    assert_enqueued_with(job: ChannelItemsUpdaterJob, args: [ { channel_id: @channel.id } ]) { Channel.fetch_and_save_items }
  end

  test "割合が 0 なら全部積む" do
    ENV["ROLLOUT_PERCENT"] = "0"

    assert_enqueued_with(job: ChannelItemsUpdaterJob, args: [ { channel_id: @channel.id } ]) { Channel.fetch_and_save_items }
  end
end
```

- [ ] **Step 2: 失敗することを確かめる**

Run: `docker compose run --rm web rails test test/models/channel_rollout_test.rb`
Expected: 1つ目のテストが FAIL (ジョブが積まれる)

- [ ] **Step 3: 実装する**

`app/models/channel.rb` の `self.fetch_and_save_items` を次にする:

```ruby
    def fetch_and_save_items
      scope = not_stopped.needs_check_now.by_check_priority
      # channel_id % 100 < ROLLOUT_PERCENT のチャンネルは fetcher (Rust) が取るので積まない
      percent = FetcherRollout.percent
      scope = scope.where("channels.id % 100 >= ?", percent) if percent.positive?

      scope.find_each do |channel|
        ChannelItemsUpdaterJob.perform_later(channel_id: channel.id)
      end
    end
```

- [ ] **Step 4: 通ることを確かめる**

Run: `docker compose run --rm web rails test test/models/channel_rollout_test.rb`
Expected: PASS

Run: `docker compose run --rm web bundle exec rubocop -c .rubocop.yml app/models/channel.rb test/models/channel_rollout_test.rb`
Expected: no offenses

- [ ] **Step 5: コミット**

```bash
git add app/models/channel.rb test/models/channel_rollout_test.rb
git commit -m "ロールアウトの対象のチャンネルはChannelItemsUpdaterJobに積まないようにする"
```

### Task 8: 遅れの監視 (`FetcherLagMonitorJob`)

**Files:**
- Create: `app/jobs/fetcher_lag_monitor_job.rb`
- Modify: `config/recurring.yml`
- Test: `test/jobs/fetcher_lag_monitor_job_test.rb`

**Interfaces:**
- Consumes: `FetcherRollout.percent` (Task 2)、`DiscoPosterJob`

- [ ] **Step 1: 失敗するテストを書く**

`test/jobs/fetcher_lag_monitor_job_test.rb`:

```ruby
require "test_helper"

class FetcherLagMonitorJobTest < ActiveJob::TestCase
  setup do
    @old = ENV["ROLLOUT_PERCENT"]
    ENV["ROLLOUT_PERCENT"] = "100"
  end

  teardown { ENV["ROLLOUT_PERCENT"] = @old }

  def lagging_channels(count)
    create_list(:channel, count, check_interval_hours: 1, last_items_checked_at: 3.hours.ago)
    clear_enqueued_jobs
  end

  test "遅れているチャンネルが10件を超えたら Discord に投稿する" do
    lagging_channels(11)

    assert_enqueued_with(job: DiscoPosterJob) { FetcherLagMonitorJob.perform_now }
    assert_match "11", enqueued_jobs.last[:args].first["content"]
  end

  test "10件以下なら投稿しない" do
    lagging_channels(10)

    assert_no_enqueued_jobs(only: DiscoPosterJob) { FetcherLagMonitorJob.perform_now }
  end

  test "間隔 + 1時間以内なら遅れに数えない" do
    create_list(:channel, 11, check_interval_hours: 1, last_items_checked_at: 90.minutes.ago)
    clear_enqueued_jobs

    assert_no_enqueued_jobs(only: DiscoPosterJob) { FetcherLagMonitorJob.perform_now }
  end

  test "停止中のチャンネルは数えない" do
    lagging_channels(11)
    ChannelStopper.create!(channel: Channel.first, reason: "test")

    assert_no_enqueued_jobs(only: DiscoPosterJob) { FetcherLagMonitorJob.perform_now }
  end

  test "割合が 0 なら何もしない" do
    ENV["ROLLOUT_PERCENT"] = "0"
    lagging_channels(11)

    assert_no_enqueued_jobs(only: DiscoPosterJob) { FetcherLagMonitorJob.perform_now }
  end
end
```

- [ ] **Step 2: 失敗することを確かめる**

Run: `docker compose run --rm web rails test test/jobs/fetcher_lag_monitor_job_test.rb`
Expected: `uninitialized constant FetcherLagMonitorJob` で FAIL

- [ ] **Step 3: 実装する**

`app/jobs/fetcher_lag_monitor_job.rb`:

```ruby
# fetcher (Rust) が止まっていないかを見る。ロールアウトの対象で、最後のチェックから
# チェック間隔 + 1時間以上たっているチャンネルが THRESHOLD 件を超えたら Discord に知らせる。
# fetcher が止まっても Rails は代わりに取らないので、ここで気づいて手で対応する
class FetcherLagMonitorJob < ApplicationJob
  queue_as :default

  THRESHOLD = 10

  def perform
    percent = FetcherRollout.percent
    return if percent.zero?

    lagging = Channel.not_stopped
      .where("channels.id % 100 < ?", percent)
      .where("channels.last_items_checked_at < NOW() - ((channels.check_interval_hours || ' hours')::interval + interval '1 hour')")
      .count
    return if lagging <= THRESHOLD

    DiscoPosterJob.perform_later(
      content: "[Fetcher] #{lagging} channels are overdue (last check older than interval + 1h). Is the fetcher running?",
      channel: :admin
    )
  end
end
```

`config/recurring.yml` の `channel_fetcher:` の直後に足す:

```yaml
fetcher_lag_monitor:
  class: FetcherLagMonitorJob
  schedule: "40 * * * *"
```

- [ ] **Step 4: 通ることを確かめる**

Run: `docker compose run --rm web rails test test/jobs/fetcher_lag_monitor_job_test.rb`
Expected: PASS

Run: `docker compose run --rm web rails test`
Expected: 全体が PASS (Part 1 の確認)

Run: `docker compose run --rm web bundle exec rubocop -c .rubocop.yml`
Expected: no offenses

- [ ] **Step 5: コミット**

```bash
git add app/jobs/fetcher_lag_monitor_job.rb config/recurring.yml test/jobs/fetcher_lag_monitor_job_test.rb
git commit -m "fetcherの遅れを1時間ごとに見てDiscordに知らせるFetcherLagMonitorJobを追加する"
```

---

## Part 2: Rust の fetcher

作業ブランチは Part 1 のブランチの続き (Part 1 の PR をマージしたあと、main から `feature/fetcher-run-mode` を切る)。Task 9〜14 で1つの PR にする。

### Task 9: SSRF の対策を固める

**Files:**
- Modify: `fetcher/src/http/address_guard.rs` (`is_blocked_v6`)

**Interfaces:**
- Produces: `is_blocked_ip` が NAT64・6to4・Teredo・IPv4 互換アドレスも判定する

- [ ] **Step 1: 失敗するテストを書く**

`fetcher/src/http/address_guard.rs` の末尾に足す:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn blocked(s: &str) -> bool {
        is_blocked_ip(s.parse().unwrap())
    }

    #[test]
    fn nat64_follows_the_embedded_ipv4() {
        assert!(blocked("64:ff9b::192.168.0.1"));
        assert!(blocked("64:ff9b::7f00:1"));
        assert!(!blocked("64:ff9b::8.8.8.8"));
        // ローカル用の NAT64 は中の宛先が分からないので塞ぐ
        assert!(blocked("64:ff9b:1::8.8.8.8"));
    }

    #[test]
    fn six_to_four_follows_the_embedded_ipv4() {
        assert!(blocked("2002:c0a8:0001::1")); // 192.168.0.1
        assert!(blocked("2002:7f00:0001::1")); // 127.0.0.1
        assert!(!blocked("2002:0808:0808::1")); // 8.8.8.8
    }

    #[test]
    fn teredo_is_blocked() {
        assert!(blocked("2001:0:4136:e378:8000:63bf:3fff:fdd2"));
        assert!(!blocked("2001:4860:4860::8888"));
    }

    #[test]
    fn ipv4_compatible_follows_the_embedded_ipv4() {
        assert!(blocked("::192.168.0.1"));
        assert!(blocked("::1"));
        assert!(blocked("::"));
        assert!(!blocked("::8.8.8.8"));
    }

    #[test]
    fn existing_ranges_are_still_blocked() {
        assert!(blocked("::ffff:10.0.0.1"));
        assert!(blocked("fe80::1"));
        assert!(blocked("fd00::1"));
        assert!(blocked("169.254.169.254"));
        assert!(!blocked("2606:4700::1111"));
        assert!(!blocked("1.1.1.1"));
    }
}
```

- [ ] **Step 2: 失敗することを確かめる**

Run: `cd fetcher && cargo test address_guard`
Expected: `nat64_follows_the_embedded_ipv4` などが FAIL

- [ ] **Step 3: 実装する**

`is_blocked_v6` を次にする:

```rust
fn embedded_v4(hi: u16, lo: u16) -> Ipv4Addr {
    let [a, b] = hi.to_be_bytes();
    let [c, d] = lo.to_be_bytes();
    Ipv4Addr::new(a, b, c, d)
}

fn is_blocked_v6(ip: Ipv6Addr) -> bool {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return is_blocked_v4(v4);
    }
    let seg = ip.segments();
    // IPv4 互換アドレス (::a.b.c.d、非推奨)。:: と ::1 も 0.0.0.0/8 として塞がれる
    if seg[..6] == [0; 6] {
        return is_blocked_v4(embedded_v4(seg[6], seg[7]));
    }
    // NAT64 の well-known prefix (64:ff9b::/96): 末尾 32 ビットの IPv4 で判定する
    if seg[..6] == [0x64, 0xff9b, 0, 0, 0, 0] {
        return is_blocked_v4(embedded_v4(seg[6], seg[7]));
    }
    // ローカル用の NAT64 (64:ff9b:1::/48) は中の宛先の形が決まっていないので塞ぐ
    if seg[..3] == [0x64, 0xff9b, 1] {
        return true;
    }
    // 6to4 (2002::/16): 続く 32 ビットの IPv4 で判定する
    if seg[0] == 0x2002 {
        return is_blocked_v4(embedded_v4(seg[1], seg[2]));
    }
    // Teredo (2001:0::/32): 中の宛先を確かめにくいので塞ぐ
    if seg[0] == 0x2001 && seg[1] == 0 {
        return true;
    }
    let first = seg[0];
    ip.is_multicast() // ff00::/8
        || (first & 0xffc0) == 0xfe80 // fe80::/10 (リンクローカル)
        || (first & 0xfe00) == 0xfc00 // fc00::/7 (ULA)
}
```

(`is_loopback` と `is_unspecified` は IPv4 互換アドレスの判定に含まれるので消してよい。)

ファイル先頭のモジュールコメントに1行足す: `//! IPv6 の中に IPv4 を埋め込む形式 (IPv4 射影・IPv4 互換・NAT64・6to4) は中の IPv4 で判定し、Teredo は塞ぐ。`

- [ ] **Step 4: 通ることを確かめる**

Run: `cd fetcher && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add fetcher/src/http/address_guard.rs
git commit -m "fetcherの取得先の検査で、IPv6に埋め込まれたIPv4とTeredoも塞ぐ"
```

### Task 10: `result` のペイロードと、契約のサンプル (Rust)

**Files:**
- Create: `fetcher/src/result.rs`
- Modify: `fetcher/src/lib.rs` (`pub mod result;`)
- Modify: `fetcher/src/http/mod.rs` (`DEFAULT_MAX_BODY_BYTES` を 64MB に)
- Create: `fetcher/tests/result_samples.rs`
- Create: `fetcher/testdata/result/rss_basic.json`、`itunes_podcast.json`、`atom_basic.json`、`rss_image_url_noise.json` (テストで生成する)

**Interfaces:**
- Consumes: `fetcher::prepare`、`shape::channel::channel_meta`、`shape::entry::{draft_entries, finalize_entries, DataExtra, EntryDraft}`
- Produces (`fetcher::result`):
  - `ResultPayload { fetched: bool, error: Option<ResultError>, final_url: Option<String>, register_proxy_urls: Vec<String>, channel: Option<ResultChannel>, entries: Vec<ResultEntry>, latest_guids: Vec<String> }` (Serialize/Deserialize/PartialEq)
  - `ResultError { kind: String, message: String }`
  - `ResultChannel { title, description, site_url, image_url: Option<String>, applied_filters: Vec<String>, filter_details: serde_json::Map<String, Value> }`
  - `ResultEntry { guid, title, url: String, image_url: Option<String>, published_at: String, data: ResultEntryData }`
  - `ResultEntryData { entry_id, title, url, published, summary, itunes_subtitle, enclosure_url, enclosure_type: Option<String> }`
  - `ResultPayload::failed(kind: &str, message: impl Into<String>) -> ResultPayload`
  - `latest_guids(feed: &RawFeed) -> Vec<String>`
  - `data_extra_by_guid(drafts: &[EntryDraft]) -> HashMap<String, DataExtra>`
  - `result_channel(meta: ChannelMeta, applied_filters: Vec<String>, filter_details: Map<String, Value>) -> ResultChannel`
  - `result_entry(entry: ShapedEntry, extra: Option<&DataExtra>) -> ResultEntry`
  - `sample_payload(body: &[u8], feed_url: &str) -> anyhow::Result<ResultPayload>` (HTTP を使わず、全 entry を新しいものとして作る。OGP は取れなかった扱い)

- [ ] **Step 1: 失敗するテストを書く**

`fetcher/src/result.rs` (テストだけ先に):

```rust
//! Rails の POST /fetcher/leases/:channel_id/result に送る取得結果。
//! 形は Rails の FetchResultApplier と、testdata/result/*.json のサンプルで固定する

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse::extract::{RawEntry, RawFeed};

    fn raw(entry_id: Option<&str>, url: Option<&str>, hour: Option<u32>) -> RawEntry {
        RawEntry {
            entry_id: entry_id.map(str::to_string),
            url: url.map(str::to_string),
            published: hour.map(|h| format!("2026-09-25T{h:02}:00:00Z").parse().unwrap()),
            ..Default::default()
        }
    }

    fn feed(entries: Vec<RawEntry>) -> RawFeed {
        RawFeed {
            format: crate::model::FeedFormat::Rss,
            title: None,
            description: None,
            url: None,
            links: vec![],
            itunes_image: None,
            entries,
        }
    }

    #[test]
    fn latest_guids_are_entry_ids_and_urls_of_the_two_newest() {
        let f = feed(vec![
            raw(Some("old"), Some("https://e/old"), Some(1)),
            raw(Some("newest"), Some("https://e/newest"), Some(9)),
            raw(None, Some("https://e/no-date"), None),
            raw(Some(" "), Some("https://e/second"), Some(5)),
        ]);
        assert_eq!(
            latest_guids(&f),
            vec!["https://e/second", "newest", "https://e/newest"]
        );
    }

    #[test]
    fn failed_payload_has_no_entries() {
        let p = ResultPayload::failed("timeout", "timed out");
        assert!(!p.fetched);
        assert_eq!(p.error.as_ref().unwrap().kind, "timeout");
        assert!(p.entries.is_empty());
        assert_eq!(
            serde_json::to_value(&p).unwrap()["error"],
            serde_json::json!({ "kind": "timeout", "message": "timed out" })
        );
    }
}
```

`fetcher/tests/result_samples.rs`:

```rust
//! Rust と Rails の間の result の形を固定する。同じファイルを Rails の
//! test/services/fetch_result_contract_test.rb が読み、golden どおりの item ができることを確かめる。
//! 形を変えたら `UPDATE_RESULT_SAMPLES=1 cargo test --test result_samples` で作り直し、Rails 側のテストも通すこと

use std::fs;
use std::path::{Path, PathBuf};

use fetcher::result::{ResultPayload, sample_payload};
use pretty_assertions::assert_eq;

const SAMPLES: &[&str] = &["rss_basic", "itunes_podcast", "atom_basic", "rss_image_url_noise"];

fn testdata() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata")
}

fn feed_url_for(name: &str) -> String {
    match fs::read_to_string(testdata().join("fixtures").join(format!("{name}.url"))) {
        Ok(s) => s.lines().next().unwrap_or_default().trim().to_string(),
        Err(_) => format!("https://example.com/{name}/feed.xml"),
    }
}

#[test]
fn result_samples_match_the_payload_built_from_fixtures() {
    let update = std::env::var_os("UPDATE_RESULT_SAMPLES").is_some();
    fs::create_dir_all(testdata().join("result")).unwrap();
    for name in SAMPLES {
        let body = fs::read(testdata().join("fixtures").join(format!("{name}.xml"))).unwrap();
        let actual = sample_payload(&body, &feed_url_for(name)).unwrap();
        let path = testdata().join("result").join(format!("{name}.json"));
        if update {
            fs::write(&path, serde_json::to_string_pretty(&actual).unwrap() + "\n").unwrap();
        }
        let expected: ResultPayload =
            serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(expected, actual, "sample: {name}");
    }
}
```

- [ ] **Step 2: 失敗することを確かめる**

`fetcher/src/lib.rs` に `pub mod result;` を足してから:

Run: `cd fetcher && cargo test result`
Expected: `cannot find function latest_guids` などのコンパイルエラーで FAIL

- [ ] **Step 3: 実装する**

`fetcher/src/result.rs` のテストの上に足す:

```rust
use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::model::{ChannelMeta, ShapedEntry};
use crate::parse::extract::{RawEntry, RawFeed};
use crate::ruby::ruby_strip;
use crate::shape;
use crate::shape::entry::{DataExtra, EntryDraft};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResultError {
    pub kind: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResultChannel {
    pub title: Option<String>,
    pub description: Option<String>,
    pub site_url: Option<String>,
    pub image_url: Option<String>,
    pub applied_filters: Vec<String>,
    pub filter_details: Map<String, Value>,
}

/// items.data に入れる8つのキー (Rails の画面が使うのは summary・itunes_subtitle・enclosure_*)
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ResultEntryData {
    pub entry_id: Option<String>,
    pub title: Option<String>,
    pub url: Option<String>,
    pub published: Option<String>,
    pub summary: Option<String>,
    pub itunes_subtitle: Option<String>,
    pub enclosure_url: Option<String>,
    pub enclosure_type: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResultEntry {
    pub guid: String,
    pub title: String,
    pub url: String,
    pub image_url: Option<String>,
    pub published_at: String,
    pub data: ResultEntryData,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResultPayload {
    pub fetched: bool,
    pub error: Option<ResultError>,
    /// リダイレクトしたときだけ、最後に取れた URL
    pub final_url: Option<String>,
    /// proxy を通して取れた URL (Rails がホストを proxy_required_domains に登録する)
    pub register_proxy_urls: Vec<String>,
    /// Rails の Channel.build_from が作らない形式や、バリデーションに通らないときは None (更新しない)
    pub channel: Option<ResultChannel>,
    /// 新しい entry だけ。公開日時の昇順
    pub entries: Vec<ResultEntry>,
    /// 新着通知の対象 (公開日時が新しい2件の entry_id と url)
    pub latest_guids: Vec<String>,
}

impl ResultPayload {
    pub fn failed(kind: &str, message: impl Into<String>) -> Self {
        Self {
            fetched: false,
            error: Some(ResultError {
                kind: kind.to_string(),
                message: message.into(),
            }),
            final_url: None,
            register_proxy_urls: vec![],
            channel: None,
            entries: vec![],
            latest_guids: vec![],
        }
    }
}

fn entry_id_of(e: &RawEntry) -> Option<String> {
    e.entry_id.clone().filter(|id| !ruby_strip(id).is_empty())
}

/// Rails の notifiable_guids と同じ: published のある entry を published の昇順に並べた最後の2件の、entry_id と url
pub fn latest_guids(feed: &RawFeed) -> Vec<String> {
    let mut dated: Vec<&RawEntry> = feed.entries.iter().filter(|e| e.published.is_some()).collect();
    dated.sort_by_key(|e| e.published);
    let start = dated.len().saturating_sub(2);
    dated[start..]
        .iter()
        .flat_map(|e| [entry_id_of(e), e.url.clone()])
        .flatten()
        .collect()
}

/// finalize_entries は guid の重複を後勝ちで1つにするので、data の残りのキーも後勝ちで引けるようにする
pub fn data_extra_by_guid(drafts: &[EntryDraft]) -> HashMap<String, DataExtra> {
    drafts
        .iter()
        .map(|d| (d.guid.clone(), d.data_extra.clone()))
        .collect()
}

pub fn result_channel(
    meta: ChannelMeta,
    applied_filters: Vec<String>,
    filter_details: Map<String, Value>,
) -> ResultChannel {
    ResultChannel {
        title: meta.title,
        description: meta.description,
        site_url: meta.site_url,
        image_url: meta.image_url,
        applied_filters,
        filter_details,
    }
}

pub fn result_entry(entry: ShapedEntry, extra: Option<&DataExtra>) -> ResultEntry {
    let extra = extra.cloned().unwrap_or_default();
    ResultEntry {
        guid: entry.guid,
        title: entry.title,
        url: entry.url,
        image_url: entry.image_url,
        published_at: entry.published_at,
        data: ResultEntryData {
            entry_id: extra.entry_id,
            title: extra.title,
            url: extra.url,
            published: extra.published,
            summary: entry.data.summary,
            itunes_subtitle: entry.data.itunes_subtitle,
            enclosure_url: entry.data.enclosure_url,
            enclosure_type: entry.data.enclosure_type,
        },
    }
}

/// 契約のサンプル用: HTTP を使わず、全 entry を新しいものとして result を作る (OGP は取れなかった扱い)
pub fn sample_payload(body: &[u8], feed_url: &str) -> anyhow::Result<ResultPayload> {
    let prepared = crate::prepare(body, feed_url)?;
    let meta = shape::channel::channel_meta(&prepared.feed, feed_url, None);
    let site_url = meta.as_ref().and_then(|m| m.site_url.clone());
    let (drafts, _) = shape::entry::draft_entries(&prepared.feed, site_url.as_deref());
    let extras = data_extra_by_guid(&drafts);
    let (entries, _) =
        shape::entry::finalize_entries(drafts.into_iter().map(|d| (d, None, false)).collect());
    Ok(ResultPayload {
        fetched: true,
        error: None,
        final_url: None,
        register_proxy_urls: vec![],
        channel: meta.map(|m| {
            result_channel(m, prepared.applied_filters.clone(), prepared.filter_details.clone())
        }),
        entries: entries
            .into_iter()
            .map(|e| {
                let extra = extras.get(&e.guid);
                result_entry(e, extra)
            })
            .collect(),
        latest_guids: latest_guids(&prepared.feed),
    })
}
```

`DataExtra` と `EntryDraft::data_extra` が `pub` でなければ `pub` にする (`fetcher/src/shape/entry.rs`)。`DataExtra` に `Clone` と `Default` が無ければ derive に足す。

`fetcher/src/http/mod.rs` の上限を変える:

```rust
/// 本番に 57MB のフィードがあり、Rails はそれを読めているので、余裕を見て 64MB にする
pub const DEFAULT_MAX_BODY_BYTES: usize = 64 * 1024 * 1024;
```

サンプルを作る:

Run: `cd fetcher && UPDATE_RESULT_SAMPLES=1 cargo test --test result_samples`
Expected: `fetcher/testdata/result/*.json` が4つできる。中身を開いて、`entries` の guid・title・published_at が `testdata/fixtures/<name>.golden.json` と同じであること、`data.entry_id` などが入っていることを目で確かめる

- [ ] **Step 4: 通ることを確かめる**

Run: `cd fetcher && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
Expected: PASS (`UPDATE_RESULT_SAMPLES` なしで)

- [ ] **Step 5: コミット**

```bash
git add fetcher/src/result.rs fetcher/src/lib.rs fetcher/src/http/mod.rs fetcher/src/shape/entry.rs fetcher/tests/result_samples.rs fetcher/testdata/result
git commit -m "fetcherにRailsへ送る取得結果の形と契約のサンプルを追加し、本文の上限を64MBにする"
```

### Task 11: 契約のサンプルを Rails で読む

**Files:**
- Create: `test/services/fetch_result_contract_test.rb`

**Interfaces:**
- Consumes: `fetcher/testdata/result/*.json` (Task 10)、`fetcher/testdata/fixtures/*.golden.json`、`FetchResultApplier` (Task 5)

- [ ] **Step 1: テストを書く**

`test/services/fetch_result_contract_test.rb`:

```ruby
require "test_helper"

# fetcher (Rust) が送る result のサンプル (fetcher/testdata/result/*.json) を FetchResultApplier に通し、
# Rails の取り込み処理で作った golden (fetcher/testdata/fixtures/*.golden.json) と同じ item ができることを確かめる。
# Rust 側は fetcher/tests/result_samples.rs が、自分の出力とサンプルが一致することを確かめる
class FetchResultContractTest < ActiveSupport::TestCase
  RESULT_DIR = Rails.root.join("fetcher/testdata/result")
  FIXTURE_DIR = Rails.root.join("fetcher/testdata/fixtures")

  setup do
    Sentry.stubs(:capture_message)
    Sentry.stubs(:capture_exception)
  end

  RESULT_DIR.glob("*.json").each do |path|
    name = path.basename(".json").to_s

    test "#{name} のサンプルから golden どおりの item ができる" do
      payload = JSON.parse(path.read)
      golden = JSON.parse(FIXTURE_DIR.join("#{name}.golden.json").read)
      url_path = FIXTURE_DIR.join("#{name}.url")
      feed_url = url_path.exist? ? url_path.read.lines.first.strip : "https://example.com/#{name}/feed.xml"
      channel = Channel.create!(title: "Before", feed_url:)

      applier = FetchResultApplier.new(channel:)
      assert applier.apply_channel!(payload)
      applier.save_items!(payload["entries"], latest_guids: payload["latest_guids"])

      expected = golden["entries"].map { |e|
        e.slice("guid", "title", "url", "image_url", "published_at").merge("data" => e["data"].compact)
      }
      actual = channel.items.order(:published_at, :guid).map { |item|
        { "guid" => item.guid, "title" => item.title, "url" => item.url, "image_url" => item.image_url,
          "published_at" => item.published_at.utc.iso8601,
          "data" => FetcherGolden::DATA_KEYS.index_with { item.data&.dig(_1)&.to_s }.compact }
      }
      assert_equal expected.sort_by { [ _1["published_at"], _1["guid"] ] }, actual

      if golden["channel"]
        channel.reload
        assert_equal golden["channel"].slice("title", "description", "site_url", "image_url"),
                     { "title" => channel.title, "description" => channel.description,
                       "site_url" => channel.site_url, "image_url" => channel.image_url }
      end
    end
  end
end
```

- [ ] **Step 2: 通ることを確かめる**

Run: `docker compose run --rm web rails test test/services/fetch_result_contract_test.rb`
Expected: 4つとも PASS。落ちたら、Rust のサンプルと Rails の保存のどちらが golden とずれているかを調べる (golden は Rails の取り込みの正解なので、golden を書き換えて合わせてはいけない)

- [ ] **Step 3: 片方だけ形を変えると落ちることを確かめる**

`fetcher/testdata/result/rss_basic.json` の最初の entry の `"published_at"` を `"published"` に一時的に書き換えて、Rails のテストが落ちることを確かめる。確かめたら `git checkout fetcher/testdata/result/rss_basic.json` で戻す。

Run: `docker compose run --rm web rails test test/services/fetch_result_contract_test.rb`
Expected: rss_basic が FAIL → 戻したあと PASS

Run: `docker compose run --rm web bundle exec rubocop -c .rubocop.yml test/services/fetch_result_contract_test.rb`
Expected: no offenses

- [ ] **Step 4: コミット**

```bash
git add test/services/fetch_result_contract_test.rb
git commit -m "fetcherのresultのサンプルをFetchResultApplierに通し、goldenどおりのitemができることを確かめる"
```

### Task 12: Rails API のクライアント (Rust)

**Files:**
- Create: `fetcher/src/api_client.rs`
- Modify: `fetcher/src/lib.rs` (`pub mod api_client;`)
- Test: `fetcher/tests/api_client.rs`

**Interfaces:**
- Consumes: `fetcher::result::ResultPayload` (Task 10)、`fetcher::dispatcher_client::NewGuidQuery` (既存)
- Produces (`fetcher::api_client`):
  - `Lease { channel_id: i64, feed_url: String, site_url: Option<String>, use_proxy: bool }` (Deserialize, Clone)
  - `LeaseBatch { leases: Vec<Lease>, proxy_required_domains: Vec<String> }`
  - `Delivery` (`Accepted` | `LeaseLost`)
  - `ApiClient::new(base_url: &str, token: &str) -> anyhow::Result<ApiClient>`
  - `ApiClient::with_retry_base(self, d: Duration) -> ApiClient` (テストで送り直しの待ちを短くする)
  - `async fn leases(&self, max: usize) -> anyhow::Result<LeaseBatch>`
  - `async fn new_flags(&self, channel_id: i64, entries: &[NewGuidQuery]) -> anyhow::Result<Vec<bool>>`
  - `async fn send_result(&self, channel_id: i64, payload: &ResultPayload) -> anyhow::Result<Delivery>` (接続エラー・5xx は最大5回送り直す。409 は `LeaseLost`。それ以外の 4xx はエラー)

- [ ] **Step 1: 失敗するテストを書く**

`fetcher/tests/api_client.rs`:

```rust
use std::time::Duration;

use fetcher::api_client::{ApiClient, Delivery};
use fetcher::dispatcher_client::NewGuidQuery;
use fetcher::result::ResultPayload;
use wiremock::matchers::{body_json, header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn client(server: &MockServer) -> ApiClient {
    ApiClient::new(&server.uri(), "tok")
        .unwrap()
        .with_retry_base(Duration::from_millis(1))
}

#[tokio::test]
async fn leases_sends_max_with_the_token() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases"))
        .and(header("authorization", "Bearer tok"))
        .and(body_json(serde_json::json!({ "max": 3 })))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "leases": [{ "channel_id": 7, "feed_url": "https://e/f.xml", "site_url": null, "use_proxy": false }],
            "proxy_required_domains": ["p.example"]
        })))
        .mount(&server)
        .await;

    let batch = client(&server).leases(3).await.unwrap();
    assert_eq!(batch.leases[0].channel_id, 7);
    assert_eq!(batch.proxy_required_domains, vec!["p.example"]);
}

#[tokio::test]
async fn new_flags_posts_entries_to_guid_lookups() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/channels/7/guid_lookups"))
        .and(body_json(serde_json::json!({ "entries": [{ "entry_id": "a", "url": null }] })))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "new": [true] })))
        .mount(&server)
        .await;

    let flags = client(&server)
        .new_flags(7, &[NewGuidQuery { entry_id: Some("a".into()), url: None }])
        .await
        .unwrap();
    assert_eq!(flags, vec![true]);
}

#[tokio::test]
async fn send_result_retries_server_errors() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/7/result"))
        .respond_with(ResponseTemplate::new(503))
        .up_to_n_times(2)
        .with_priority(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/7/result"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "created": 0, "skipped": 0 })))
        .with_priority(2)
        .mount(&server)
        .await;

    let d = client(&server)
        .send_result(7, &ResultPayload::failed("timeout", "t"))
        .await
        .unwrap();
    assert_eq!(d, Delivery::Accepted);
    assert_eq!(server.received_requests().await.unwrap().len(), 3);
}

#[tokio::test]
async fn send_result_treats_202_as_accepted() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/7/result"))
        .respond_with(ResponseTemplate::new(202).set_body_json(serde_json::json!({ "queued": 300 })))
        .mount(&server)
        .await;

    let d = client(&server)
        .send_result(7, &ResultPayload::failed("timeout", "t"))
        .await
        .unwrap();
    assert_eq!(d, Delivery::Accepted);
}

#[tokio::test]
async fn send_result_gives_up_on_conflict_without_retrying() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/7/result"))
        .respond_with(ResponseTemplate::new(409))
        .mount(&server)
        .await;

    let d = client(&server)
        .send_result(7, &ResultPayload::failed("timeout", "t"))
        .await
        .unwrap();
    assert_eq!(d, Delivery::LeaseLost);
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

#[tokio::test]
async fn send_result_does_not_retry_other_client_errors() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/7/result"))
        .respond_with(ResponseTemplate::new(422))
        .mount(&server)
        .await;

    assert!(client(&server)
        .send_result(7, &ResultPayload::failed("timeout", "t"))
        .await
        .is_err());
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

#[tokio::test]
async fn send_result_fails_after_exhausting_retries() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/7/result"))
        .respond_with(ResponseTemplate::new(500))
        .mount(&server)
        .await;

    assert!(client(&server)
        .send_result(7, &ResultPayload::failed("timeout", "t"))
        .await
        .is_err());
    assert_eq!(server.received_requests().await.unwrap().len(), 6);
}
```

- [ ] **Step 2: 失敗することを確かめる**

`fetcher/src/lib.rs` に `pub mod api_client;` を足し、空の `fetcher/src/api_client.rs` を作ってから:

Run: `cd fetcher && cargo test --test api_client`
Expected: `unresolved import fetcher::api_client::ApiClient` で FAIL

- [ ] **Step 3: 実装する**

`fetcher/src/api_client.rs`:

```rust
//! Rails の /fetcher/* API のクライアント (本番の書き込み経路)。
//! 影モードの dispatcher_client とは別に持つ (影モードは dispatcher と一緒に廃止する)

use std::time::Duration;

use serde::Deserialize;

use crate::dispatcher_client::NewGuidQuery;
use crate::result::ResultPayload;

#[derive(Debug, Clone, Deserialize)]
pub struct Lease {
    pub channel_id: i64,
    pub feed_url: String,
    pub site_url: Option<String>,
    pub use_proxy: bool,
}

#[derive(Debug, Deserialize)]
pub struct LeaseBatch {
    pub leases: Vec<Lease>,
    pub proxy_required_domains: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Delivery {
    /// 保存された (200) か、保存がジョブに回された (202)
    Accepted,
    /// lease がもう自分のものではない (409)。結果は捨てる
    LeaseLost,
}

/// result の送り直しの回数 (最初の1回とは別に)
const MAX_RETRIES: u32 = 5;

pub struct ApiClient {
    base_url: String,
    token: String,
    client: reqwest::Client,
    retry_base: Duration,
}

impl ApiClient {
    pub fn new(base_url: &str, token: &str) -> anyhow::Result<Self> {
        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            token: token.to_string(),
            // Rails はリクエストの中で保存まで行う (Heroku のルーターの上限は30秒)
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(60))
                .build()?,
            retry_base: Duration::from_secs(2),
        })
    }

    pub fn with_retry_base(mut self, d: Duration) -> Self {
        self.retry_base = d;
        self
    }

    pub async fn leases(&self, max: usize) -> anyhow::Result<LeaseBatch> {
        Ok(self
            .client
            .post(format!("{}/fetcher/leases", self.base_url))
            .bearer_auth(&self.token)
            .json(&serde_json::json!({ "max": max }))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?)
    }

    pub async fn new_flags(
        &self,
        channel_id: i64,
        entries: &[NewGuidQuery],
    ) -> anyhow::Result<Vec<bool>> {
        #[derive(Deserialize)]
        struct Res {
            new: Vec<bool>,
        }
        let res: Res = self
            .client
            .post(format!(
                "{}/fetcher/channels/{channel_id}/guid_lookups",
                self.base_url
            ))
            .bearer_auth(&self.token)
            .json(&serde_json::json!({ "entries": entries }))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        anyhow::ensure!(
            res.new.len() == entries.len(),
            "guid_lookups returned {} flags for {} entries",
            res.new.len(),
            entries.len()
        );
        Ok(res.new)
    }

    pub async fn send_result(
        &self,
        channel_id: i64,
        payload: &ResultPayload,
    ) -> anyhow::Result<Delivery> {
        let url = format!("{}/fetcher/leases/{channel_id}/result", self.base_url);
        let mut attempt = 0;
        loop {
            let res = self
                .client
                .post(&url)
                .bearer_auth(&self.token)
                .json(payload)
                .send()
                .await;
            let retryable_error = match res {
                Ok(r) if r.status().is_success() => return Ok(Delivery::Accepted),
                Ok(r) if r.status() == reqwest::StatusCode::CONFLICT => {
                    return Ok(Delivery::LeaseLost);
                }
                Ok(r) if r.status().is_server_error() => anyhow::anyhow!("HTTP {}", r.status()),
                Ok(r) => anyhow::bail!("result rejected with HTTP {}", r.status()),
                Err(e) => e.into(),
            };
            if attempt >= MAX_RETRIES {
                return Err(retryable_error.context(format!("gave up after {} attempts", attempt + 1)));
            }
            tracing::warn!(channel_id, attempt, error = %retryable_error, "failed to send result, retrying");
            tokio::time::sleep(self.retry_base * 2u32.pow(attempt)).await;
            attempt += 1;
        }
    }
}
```

`NewGuidQuery` に `Deserialize` が要るなら足さない (送るだけなので `Serialize` だけで足りる)。

- [ ] **Step 4: 通ることを確かめる**

Run: `cd fetcher && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add fetcher/src/api_client.rs fetcher/src/lib.rs fetcher/tests/api_client.rs
git commit -m "fetcherにRailsの/fetcher/* APIのクライアントを追加する"
```

### Task 13: 1チャンネルの処理と常駐ループ (`run`)

**Files:**
- Create: `fetcher/src/pipeline.rs`
- Create: `fetcher/src/run.rs`
- Modify: `fetcher/src/lib.rs` (`pub mod pipeline; pub mod run;`)
- Modify: `fetcher/src/main.rs` (`Run` サブコマンド)
- Test: `fetcher/tests/run_e2e.rs`

**Interfaces:**
- Consumes: `ApiClient`・`Lease`・`Delivery` (Task 12)、`fetcher::result::*` (Task 10)、`HttpClient`・`HttpConfig`、`ogp::fetch_ogp`、`shape::*`
- Produces:
  - `pipeline::process_lease(lease: &Lease, http: &HttpClient, api: &ApiClient, proxy_domains: &HashSet<String>) -> anyhow::Result<ResultPayload>` (`Err` は「結果を送らずに lease の期限切れに任せる」= guid の照会に失敗したとき)
  - `run::RunOptions { api_url: String, token: String, concurrency: usize, idle_wait: Duration, deadline: Duration, result_retry_base: Duration, http: HttpConfig }`
  - `run::run(opts: RunOptions, shutdown: impl Future<Output = ()>) -> anyhow::Result<()>`

- [ ] **Step 1: 失敗するテストを書く**

`fetcher/tests/run_e2e.rs`:

```rust
use std::time::Duration;

use fetcher::http::{DEFAULT_MAX_BODY_BYTES, HttpConfig};
use fetcher::run::{RunOptions, run};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

fn http_config() -> HttpConfig {
    HttpConfig {
        user_agent: "Faraday v2.14.3".into(),
        connect_timeout: Duration::from_secs(2),
        total_timeout: Duration::from_secs(5),
        proxy: None,
        min_host_interval: Duration::from_millis(0),
        max_body_bytes: DEFAULT_MAX_BODY_BYTES,
        // モックサーバは 127.0.0.1 で動くので、テストでだけ許可する
        allow_private_addresses: true,
    }
}

fn options(api: &MockServer, deadline: Duration) -> RunOptions {
    RunOptions {
        api_url: api.uri(),
        token: "tok".into(),
        concurrency: 2,
        idle_wait: Duration::from_millis(50),
        deadline,
        result_retry_base: Duration::from_millis(1),
        http: http_config(),
    }
}

fn rss(base: &str) -> String {
    format!(
        r#"<rss version="2.0"><channel><title>T</title><link>{base}/</link><description>d</description>
        <item><title>A</title><link>{base}/a</link><guid isPermaLink="false">ga</guid><pubDate>Wed, 24 Sep 2026 00:00:00 +0000</pubDate></item>
        <item><title>B</title><link>{base}/b</link><guid isPermaLink="false">gb</guid><pubDate>Wed, 24 Sep 2026 01:00:00 +0000</pubDate></item>
        </channel></rss>"#
    )
}

/// 1回目の貸し出しで lease を1つ返し、2回目以降は空を返す
async fn mount_one_lease(api: &MockServer, feed_url: String) {
    Mock::given(method("POST"))
        .and(path("/fetcher/leases"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "leases": [{ "channel_id": 1, "feed_url": feed_url, "site_url": null, "use_proxy": false }],
            "proxy_required_domains": []
        })))
        .up_to_n_times(1)
        .with_priority(1)
        .mount(api)
        .await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases"))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            serde_json::json!({ "leases": [], "proxy_required_domains": [] }),
        ))
        .with_priority(2)
        .mount(api)
        .await;
}

async fn result_bodies(api: &MockServer) -> Vec<serde_json::Value> {
    api.received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r: &&Request| r.url.path() == "/fetcher/leases/1/result")
        .map(|r| serde_json::from_slice(&r.body).unwrap())
        .collect()
}

/// result が届くまで待ってから止める
async fn shutdown_after_result(api: &MockServer) {
    for _ in 0..200 {
        if !result_bodies(api).await.is_empty() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("result was never sent");
}

#[tokio::test]
async fn sends_only_new_entries_with_ogp_and_latest_guids() {
    let site = MockServer::start().await;
    Mock::given(path("/feed.xml"))
        .respond_with(ResponseTemplate::new(200).set_body_string(rss(&site.uri())))
        .mount(&site)
        .await;
    // サイトとエントリーの OGP
    Mock::given(path("/"))
        .respond_with(ResponseTemplate::new(200).set_body_string(
            r#"<html><head><meta property="og:image" content="https://img.example/site.png"></head></html>"#,
        ))
        .mount(&site)
        .await;
    Mock::given(path("/b"))
        .respond_with(ResponseTemplate::new(200).set_body_string(
            r#"<html><head><meta property="og:image" content="https://img.example/b.png"></head></html>"#,
        ))
        .mount(&site)
        .await;

    let api = MockServer::start().await;
    mount_one_lease(&api, format!("{}/feed.xml", site.uri())).await;
    Mock::given(method("POST"))
        .and(path("/fetcher/channels/1/guid_lookups"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "new": [false, true] })))
        .mount(&api)
        .await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/1/result"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "created": 1, "skipped": 0 })))
        .mount(&api)
        .await;

    run(options(&api, Duration::from_secs(30)), shutdown_after_result(&api))
        .await
        .unwrap();

    let bodies = result_bodies(&api).await;
    assert_eq!(bodies.len(), 1);
    let body = &bodies[0];
    assert_eq!(body["fetched"], true);
    assert_eq!(body["final_url"], serde_json::Value::Null);
    assert_eq!(body["channel"]["title"], "T");
    assert_eq!(body["channel"]["image_url"], "https://img.example/site.png");
    let entries = body["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["guid"], "gb");
    assert_eq!(entries[0]["image_url"], "https://img.example/b.png");
    assert_eq!(entries[0]["data"]["entry_id"], "gb");
    assert_eq!(
        body["latest_guids"],
        serde_json::json!(["ga", format!("{}/a", site.uri()), "gb", format!("{}/b", site.uri())])
    );
}

#[tokio::test]
async fn reports_the_redirected_url_and_uses_it_for_the_channel() {
    let site = MockServer::start().await;
    Mock::given(path("/old.xml"))
        .respond_with(ResponseTemplate::new(301).insert_header("location", format!("{}/new.xml", site.uri())))
        .mount(&site)
        .await;
    Mock::given(path("/new.xml"))
        .respond_with(ResponseTemplate::new(200).set_body_string(rss(&site.uri())))
        .mount(&site)
        .await;

    let api = MockServer::start().await;
    mount_one_lease(&api, format!("{}/old.xml", site.uri())).await;
    Mock::given(method("POST"))
        .and(path("/fetcher/channels/1/guid_lookups"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "new": [false, false] })))
        .mount(&api)
        .await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/1/result"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "created": 0, "skipped": 0 })))
        .mount(&api)
        .await;

    run(options(&api, Duration::from_secs(30)), shutdown_after_result(&api))
        .await
        .unwrap();

    let body = &result_bodies(&api).await[0];
    assert_eq!(body["final_url"], format!("{}/new.xml", site.uri()));
    assert!(body["entries"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn sends_a_fetch_error_as_a_failed_result() {
    let site = MockServer::start().await;
    Mock::given(path("/gone.xml"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&site)
        .await;

    let api = MockServer::start().await;
    mount_one_lease(&api, format!("{}/gone.xml", site.uri())).await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/1/result"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "created": 0, "skipped": 0 })))
        .mount(&api)
        .await;

    run(options(&api, Duration::from_secs(30)), shutdown_after_result(&api))
        .await
        .unwrap();

    let body = &result_bodies(&api).await[0];
    assert_eq!(body["fetched"], false);
    assert_eq!(body["error"]["kind"], "http_status");
}

#[tokio::test]
async fn gives_up_at_the_deadline() {
    let site = MockServer::start().await;
    Mock::given(path("/slow.xml"))
        .respond_with(ResponseTemplate::new(200).set_body_string(rss("https://e.example")).set_delay(Duration::from_secs(3)))
        .mount(&site)
        .await;

    let api = MockServer::start().await;
    mount_one_lease(&api, format!("{}/slow.xml", site.uri())).await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/1/result"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "created": 0, "skipped": 0 })))
        .mount(&api)
        .await;

    run(options(&api, Duration::from_millis(200)), shutdown_after_result(&api))
        .await
        .unwrap();

    let body = &result_bodies(&api).await[0];
    assert_eq!(body["fetched"], false);
    assert_eq!(body["error"]["kind"], "deadline");
}

#[tokio::test]
async fn finishes_the_in_flight_channel_on_shutdown_and_stops_leasing() {
    let site = MockServer::start().await;
    Mock::given(path("/feed.xml"))
        .respond_with(ResponseTemplate::new(200).set_body_string(rss(&site.uri())).set_delay(Duration::from_millis(300)))
        .mount(&site)
        .await;

    let api = MockServer::start().await;
    mount_one_lease(&api, format!("{}/feed.xml", site.uri())).await;
    Mock::given(method("POST"))
        .and(path("/fetcher/channels/1/guid_lookups"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "new": [false, false] })))
        .mount(&api)
        .await;
    Mock::given(method("POST"))
        .and(path("/fetcher/leases/1/result"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "created": 0, "skipped": 0 })))
        .mount(&api)
        .await;

    // 1回目の貸し出しは頼んだ数 (2) より少ないので、次を頼む前に idle_wait だけ待つ。
    // その待ちの途中、取得の応答 (300ms) を待っている間に止める
    let mut opts = options(&api, Duration::from_secs(30));
    opts.idle_wait = Duration::from_secs(10);
    run(opts, tokio::time::sleep(Duration::from_millis(100)))
    .await
    .unwrap();

    assert_eq!(result_bodies(&api).await.len(), 1, "in-flight result must still be sent");
    let leases = api
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|r| r.url.path() == "/fetcher/leases")
        .count();
    assert_eq!(leases, 1, "no new lease after shutdown");
}
```

- [ ] **Step 2: 失敗することを確かめる**

`fetcher/src/lib.rs` に `pub mod pipeline;` と `pub mod run;` を足し、空のファイルを作ってから:

Run: `cd fetcher && cargo test --test run_e2e`
Expected: `unresolved import fetcher::run::RunOptions` で FAIL

- [ ] **Step 3: 1チャンネルの処理を実装する**

`fetcher/src/pipeline.rs`:

```rust
//! 貸し出された1チャンネルの処理: 取得 → フィルタ → パース → 整形 → 新しい entry の照会 → OGP → result。
//! Rails の ChannelItemsUpdaterJob (update_info + fetch_and_save_items) と同じ結果になるように作る

use std::collections::HashSet;

use crate::api_client::{ApiClient, Lease};
use crate::dispatcher_client::NewGuidQuery;
use crate::http::HttpClient;
use crate::ogp::fetch_ogp;
use crate::result::{
    ResultPayload, data_extra_by_guid, latest_guids, result_channel, result_entry,
};
use crate::shape;
use crate::shape::entry::ImageCandidate;

/// guid_lookups に1回で送る entry の数
const LOOKUP_CHUNK: usize = 1000;

/// `Err` は「結果を送らずに lease の期限切れに任せる」(guid の照会ができず、新しい entry を決められない)
pub async fn process_lease(
    lease: &Lease,
    http: &HttpClient,
    api: &ApiClient,
    proxy_domains: &HashSet<String>,
) -> anyhow::Result<ResultPayload> {
    let res = match http.get_feed(&lease.feed_url, lease.use_proxy).await {
        Ok(r) => r,
        Err(e) => return Ok(ResultPayload::failed(e.kind(), e.to_string())),
    };
    // Rails は response.env.url をそのまま使う。リダイレクトしていなければ lease の feed_url と同じで、
    // res.final_url は url::Url で正規化されてしまうので使い分ける
    let base_url = if res.redirected {
        res.final_url.as_str()
    } else {
        lease.feed_url.as_str()
    };
    let register_proxy_urls = if res.register_proxy_domain {
        vec![lease.feed_url.clone()]
    } else {
        vec![]
    };
    let prepared = match crate::prepare(&res.body, base_url) {
        Ok(p) => p,
        Err(e) => return Ok(ResultPayload::failed("parse", e.to_string())),
    };

    // チャンネル情報 (Channel.save_from は final_feed_url を使う)
    let ogp = match shape::channel::ogp_target(&prepared.feed, base_url) {
        Some(target) => fetch_ogp(http, &target, proxy_domains).await,
        None => None,
    };
    let meta = shape::channel::channel_meta(&prepared.feed, base_url, ogp.as_ref());
    let site_url = meta
        .as_ref()
        .and_then(|m| m.site_url.clone())
        .or_else(|| lease.site_url.clone());

    // 新しい entry だけを残す
    let (drafts, _skipped) = shape::entry::draft_entries(&prepared.feed, site_url.as_deref());
    let queries: Vec<NewGuidQuery> = drafts
        .iter()
        .map(|d| NewGuidQuery {
            entry_id: d.raw_entry_id.clone(),
            url: d.raw_url.clone(),
        })
        .collect();
    let mut flags = Vec::with_capacity(queries.len());
    for chunk in queries.chunks(LOOKUP_CHUNK) {
        flags.extend(api.new_flags(lease.channel_id, chunk).await?);
    }
    let new_drafts: Vec<_> = drafts
        .into_iter()
        .zip(flags)
        .filter_map(|(d, is_new)| is_new.then_some(d))
        .collect();
    let extras = data_extra_by_guid(&new_drafts);

    // 画像が無い新しい entry は、記事の OGP 画像を取る (Rails と同じ)
    let mut resolved = Vec::with_capacity(new_drafts.len());
    for d in new_drafts {
        let ogp_image = if d.image == ImageCandidate::NeedsOgp {
            fetch_ogp(http, &d.url, proxy_domains)
                .await
                .and_then(|o| o.image)
        } else {
            None
        };
        resolved.push((d, ogp_image, false));
    }
    let (entries, _) = shape::entry::finalize_entries(resolved);

    Ok(ResultPayload {
        fetched: true,
        error: None,
        final_url: res.redirected.then(|| res.final_url.clone()),
        register_proxy_urls,
        channel: meta.map(|m| result_channel(m, prepared.applied_filters, prepared.filter_details)),
        entries: entries
            .into_iter()
            .map(|e| {
                let extra = extras.get(&e.guid);
                result_entry(e, extra)
            })
            .collect(),
        latest_guids: latest_guids(&prepared.feed),
    })
}
```

`ImageCandidate` に `PartialEq` があることを確かめる (影モードで `==` を使っているのであるはず)。`EntryDraft::url` が `pub` でなければ `pub` にする。

- [ ] **Step 4: 常駐ループを実装する**

`fetcher/src/run.rs`:

```rust
//! 本番の常駐モード。空いた枠の数だけ Rails から貸し出しを受け、1チャンネルずつ処理して結果を送る。
//! shutdown が来たら新しい貸し出しを止め、処理中のチャンネルを (持ち時間の範囲で) 終えてから戻る

use std::collections::HashSet;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use tokio::task::JoinSet;

use crate::api_client::{ApiClient, Delivery, Lease};
use crate::http::{HttpClient, HttpConfig};
use crate::pipeline::process_lease;
use crate::result::ResultPayload;

pub struct RunOptions {
    pub api_url: String,
    pub token: String,
    pub concurrency: usize,
    /// 貸し出しが空だったとき・失敗したときに待つ時間
    pub idle_wait: Duration,
    /// 1チャンネルの持ち時間 (lease の期限 10分より短くする)
    pub deadline: Duration,
    pub result_retry_base: Duration,
    pub http: HttpConfig,
}

async fn handle(
    lease: Lease,
    http: Arc<HttpClient>,
    api: Arc<ApiClient>,
    proxy_domains: Arc<HashSet<String>>,
    deadline: Duration,
) {
    let channel_id = lease.channel_id;
    let payload = match tokio::time::timeout(
        deadline,
        process_lease(&lease, &http, &api, &proxy_domains),
    )
    .await
    {
        Ok(Ok(p)) => p,
        Ok(Err(e)) => {
            tracing::error!(channel_id, error = %format!("{e:#}"), "gave up processing, leaving the lease to expire");
            return;
        }
        Err(_) => ResultPayload::failed("deadline", format!("exceeded {}s", deadline.as_secs())),
    };
    let fetched = payload.fetched;
    let entries = payload.entries.len();
    match api.send_result(channel_id, &payload).await {
        Ok(Delivery::Accepted) => {
            tracing::info!(channel_id, fetched, entries, "result accepted");
        }
        Ok(Delivery::LeaseLost) => {
            tracing::warn!(channel_id, "lease was lost, result discarded");
        }
        Err(e) => {
            tracing::error!(channel_id, error = %format!("{e:#}"), "failed to send result, leaving the lease to expire");
        }
    }
}

pub async fn run(opts: RunOptions, shutdown: impl Future<Output = ()>) -> anyhow::Result<()> {
    let api = Arc::new(
        ApiClient::new(&opts.api_url, &opts.token)?.with_retry_base(opts.result_retry_base),
    );
    let http = Arc::new(HttpClient::new(opts.http.clone())?);
    let mut tasks: JoinSet<()> = JoinSet::new();
    tokio::pin!(shutdown);

    loop {
        let free = opts.concurrency.saturating_sub(tasks.len());
        if free == 0 {
            tokio::select! {
                _ = &mut shutdown => break,
                _ = tasks.join_next() => continue,
            }
        }

        let batch = tokio::select! {
            _ = &mut shutdown => break,
            b = api.leases(free) => b,
        };
        let wait = match batch {
            Ok(batch) => {
                // 頼んだ数より少なければ、今は他に取るべきチャンネルが無い。続けて頼まずに待つ
                let short = batch.leases.len() < free;
                let proxy_domains: Arc<HashSet<String>> =
                    Arc::new(batch.proxy_required_domains.into_iter().collect());
                for lease in batch.leases {
                    tracing::info!(channel_id = lease.channel_id, feed_url = %lease.feed_url, "leased");
                    tasks.spawn(handle(
                        lease,
                        http.clone(),
                        api.clone(),
                        proxy_domains.clone(),
                        opts.deadline,
                    ));
                }
                short
            }
            Err(e) => {
                tracing::error!(error = %format!("{e:#}"), "failed to lease channels");
                true
            }
        };
        if wait {
            // 待っている間に終わったタスクも片付ける
            let sleep = tokio::time::sleep(opts.idle_wait);
            tokio::pin!(sleep);
            loop {
                tokio::select! {
                    _ = &mut shutdown => {
                        drain(&mut tasks).await;
                        return Ok(());
                    }
                    _ = &mut sleep => break,
                    Some(_) = tasks.join_next(), if !tasks.is_empty() => {}
                }
            }
        }
    }

    drain(&mut tasks).await;
    Ok(())
}

async fn drain(tasks: &mut JoinSet<()>) {
    tracing::info!(in_flight = tasks.len(), "shutting down, finishing in-flight channels");
    while let Some(res) = tasks.join_next().await {
        if let Err(e) = res {
            tracing::error!(error = %e, "channel task panicked");
        }
    }
}
```

- [ ] **Step 5: CLI に `run` を足す**

`fetcher/src/main.rs` の `enum Command` に足す:

```rust
    /// 本番の常駐モード: Rails から貸し出しを受けて取得し、結果を Rails に送る
    Run {
        #[arg(long, env = "FETCHER_API_URL")]
        api_url: String,
        #[arg(long, env = "FETCHER_TOKEN", hide_env_values = true)]
        token: String,
        #[arg(long, env = "FETCHER_CONCURRENCY", default_value_t = 8)]
        concurrency: usize,
        #[arg(long, env = "FETCHER_USER_AGENT", default_value = "Faraday v2.14.3")]
        user_agent: String,
        #[arg(long, env = "FEED_PROXY_URL")]
        proxy_url: Option<String>,
        #[arg(long, env = "FEED_PROXY_SECRET", hide_env_values = true)]
        proxy_secret: Option<String>,
    },
```

`match` に足す (`HttpConfig` は Shadow と同じ値):

```rust
        Command::Run {
            api_url,
            token,
            concurrency,
            user_agent,
            proxy_url,
            proxy_secret,
        } => {
            let proxy = proxy_url
                .zip(proxy_secret)
                .map(|(url, secret)| ProxyConfig { url, secret });
            fetcher::run::run(
                fetcher::run::RunOptions {
                    api_url,
                    token,
                    concurrency,
                    idle_wait: Duration::from_secs(60),
                    deadline: Duration::from_secs(5 * 60),
                    result_retry_base: Duration::from_secs(2),
                    http: HttpConfig {
                        user_agent,
                        connect_timeout: Duration::from_secs(10),
                        total_timeout: Duration::from_secs(30),
                        proxy,
                        min_host_interval: Duration::from_secs(1),
                        max_body_bytes: DEFAULT_MAX_BODY_BYTES,
                        // 内部ネットワークへの取得を防ぐ。CLI からは許可しない
                        allow_private_addresses: false,
                    },
                },
                shutdown_signal(),
            )
            .await
        }
```

`main.rs` の末尾に足す:

```rust
/// systemd の stop (SIGTERM) と Ctrl-C を待つ
async fn shutdown_signal() {
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("failed to install SIGTERM handler");
    tokio::select! {
        _ = term.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
    tracing::info!("shutdown signal received");
}
```

本番のログは journald で読むので、`run` のときは JSON 形式にする。`main` の `tracing_subscriber::fmt()` を次にする:

```rust
    let cli = Cli::parse();
    let builder = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env());
    if matches!(cli.command, Command::Run { .. }) {
        builder.json().init();
    } else {
        builder.init();
    }
    match cli.command {
```

(`RUST_LOG` が無いと何も出ないので、systemd の unit で `RUST_LOG=info` を設定する。Task 14。)

- [ ] **Step 6: 通ることを確かめる**

Run: `cd fetcher && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
Expected: PASS (`run_e2e` の5つを含む)

- [ ] **Step 7: コミット**

```bash
git add fetcher/src/pipeline.rs fetcher/src/run.rs fetcher/src/lib.rs fetcher/src/main.rs fetcher/src/shape/entry.rs fetcher/tests/run_e2e.rs
git commit -m "fetcherに、Railsから貸し出しを受けて結果を送る常駐のrunサブコマンドを追加する"
```

### Task 14: systemd の unit と README

**Files:**
- Create: `fetcher/deploy/fetcher.service`
- Create: `fetcher/deploy/fetcher.env.example`
- Modify: `fetcher/README.md` (本番の常駐モードの節を足す)
- Modify: `.gitignore` (必要なら `fetcher/deploy/fetcher.env` を足す)

**Interfaces:**
- Consumes: `fetcher run` (Task 13)

- [ ] **Step 1: unit ファイルと設定の例を書く**

`fetcher/deploy/fetcher.service`:

```ini
# fetcher の本番の常駐モード (Rails から貸し出しを受けて取得し、結果を送る)
# 置き場所の例: /etc/systemd/system/fetcher.service
[Unit]
Description=feed fetcher (run mode)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=fetcher
EnvironmentFile=/etc/fetcher/fetcher.env
Environment=RUST_LOG=info
ExecStart=/usr/local/bin/fetcher run
Restart=always
RestartSec=10
# 処理中のチャンネルを持ち時間 (5分) の範囲で終えてから止まるので、それより長く待つ
TimeoutStopSec=330
KillSignal=SIGTERM
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

`fetcher/deploy/fetcher.env.example`:

```sh
# /etc/fetcher/fetcher.env にコピーして値を入れる (このファイルには本物のトークンを書かない)
FETCHER_API_URL=https://example.com
# Rails の FETCHER_TOKENS には、このトークンの SHA-256 (16進) をワーカー名と一緒に登録する
FETCHER_TOKEN=
FETCHER_CONCURRENCY=8
# 任意: 直接取れないフィードのための proxy
# FEED_PROXY_URL=
# FEED_PROXY_SECRET=
```

- [ ] **Step 2: README に節を足す**

`fetcher/README.md` の「## golden テスト」の前に足す:

````markdown
## 本番の常駐モード (`run`)

Rails の `/fetcher/*` API から貸し出しを受けてフィードを取得し、結果を Rails に送る。Rails がモデルを通して保存する。

```bash
FETCHER_API_URL=https://... FETCHER_TOKEN=... cargo run --release -- run
```

- 空いている枠 (`FETCHER_CONCURRENCY`、既定 8) の数だけ借りる。何も無ければ60秒待つ
- 1チャンネルの持ち時間は5分。超えたら `deadline` の失敗として結果を送る
- 結果の送信は、接続エラーと 5xx なら最大5回送り直す。409 (lease を失った) なら捨てる
- SIGTERM を受けたら新しい貸し出しを止め、処理中のチャンネルを終えてから止まる
- ログは JSON で標準出力に出る (`RUST_LOG=info`)。Sentry には送らない。止まっていないかは Rails の `FetcherLagMonitorJob` が見る

### トークンの発行

```bash
token=$(openssl rand -hex 32)
echo "$token"                                   # fetcher の FETCHER_TOKEN に入れる
printf %s "$token" | shasum -a 256 | cut -d' ' -f1   # Rails の FETCHER_TOKENS に {"<ワーカー名>": "<この値>"} で入れる
```

### Linux (systemd) で常駐させる

1. `cargo build --release` で作った `target/release/fetcher` を `/usr/local/bin/fetcher` に置く
2. 専用のユーザーを作る: `sudo useradd --system --no-create-home fetcher`
3. `deploy/fetcher.env.example` を `/etc/fetcher/fetcher.env` にコピーして値を入れる (`chmod 600`、所有者は root)
4. `deploy/fetcher.service` を `/etc/systemd/system/` に置き、`sudo systemctl daemon-reload && sudo systemctl enable --now fetcher`
5. ログを見る: `journalctl -u fetcher -f`

### 段階移行

Rails の `ROLLOUT_PERCENT` (既定 0) で、`channel_id % 100` がこれ未満のチャンネルを fetcher に任せる。0 → 10 → 50 → 100 と上げる。
巻き戻すときは `ROLLOUT_PERCENT=0` にする (lease は10分で切れる)。
````

- [ ] **Step 3: 確かめる**

Run: `systemd-analyze verify fetcher/deploy/fetcher.service` (Linux で。macOS では飛ばしてよい)
Expected: エラーが出ない (ユーザーや ExecStart が無いことの警告は出てよい)

Run: `cd fetcher && cargo test`
Expected: PASS

- [ ] **Step 4: コミット**

```bash
git add fetcher/deploy/fetcher.service fetcher/deploy/fetcher.env.example fetcher/README.md
git commit -m "fetcherの常駐モードのsystemd unitと、本番での動かし方をREADMEに書く"
```

### Task 15: 手元での通し確認と PR

**Files:** なし (確認だけ)

- [ ] **Step 1: 開発環境の Rails に向けて動かす**

1. 開発用のトークンを作り、`.env` に `FETCHER_TOKENS={"dev":"<SHA-256>"}` と `ROLLOUT_PERCENT=100` を足して `foreman start -f Procfile.dev` を起動し直す
2. 開発 DB で、チェックが必要なチャンネル (`last_items_checked_at` が古いもの) があることを確かめる: `docker compose run --rm web rails runner 'p Channel.not_stopped.needs_check_now.count'`
3. `cd fetcher && FETCHER_API_URL=https://fh.lvh.me FETCHER_TOKEN=<token> RUST_LOG=info cargo run -- run` を1〜2分動かして Ctrl-C で止める

Expected:
- fetcher のログに `leased` と `result accepted` が出る
- Rails のログに `POST /fetcher/leases/:id/result` の 200 が出る
- `docker compose run --rm web rails runner 'p ChannelLease.count; p Channel.order(last_items_checked_at: :desc).limit(3).pluck(:id, :last_items_checked_at)'` で、lease が残っておらず、チェック日時が進んでいる
- 新しい item ができたチャンネルがあれば、`Item.order(:id).last` の title・url・data が妥当

確認が終わったら `.env` の `ROLLOUT_PERCENT` と `FETCHER_TOKENS` を消す。

- [ ] **Step 2: 全体のテスト**

Run: `docker compose run --rm web rails test && docker compose run --rm web bundle exec rubocop -c .rubocop.yml`
Run: `cd fetcher && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
Expected: どちらも PASS

- [ ] **Step 3: PR を作る**

Part 2 の PR を作る。本文に、本番での段階移行の手順 (下の「切り替えの手順」) を書く。

---

## 切り替えの手順 (コードの変更なし。ユーザーと一緒に行う)

1. Part 1・Part 2 をデプロイする (`ROLLOUT_PERCENT` は未設定 = 0)。Procfile に `release:` が無いので、デプロイのあと `heroku run -a feedhub rails db:migrate` で `channel_leases` を作る。0 % の間はこのテーブルを誰も触らないので、migrate を忘れても 10 % に上げるまで気づけない
2. トークンを発行し、Heroku に `FETCHER_TOKENS` を設定する。自宅の Linux マシンに fetcher を置いて systemd で起動する。ログで「貸し出しが空」になっていることを確かめる
3. JSON Feed など Rust が扱えない形式のチャンネルを、影モードのレポートで数える: `cat tmp/shadow-runs/reports/*.jsonl | jq -r 'select(.format == "json_feed" or .status == "parse_error") | "\(.channel_id) \(.error)"' | sort | uniq -c`。件数があれば対応を決める (ロールアウトの対象から外すか、fetcher で扱うか)
4. `heroku config:set -a feedhub ROLLOUT_PERCENT=10`。数時間〜1日、Sentry、1時間あたりの item 作成数、`FetcherLagMonitorJob` の投稿、fetcher のログ (409・送り直し) を見る
5. 50 → 100 と上げる
6. 100 で安定したら `heroku config:set -a feedhub SOLID_QUEUE_IN_PUMA=1` → `heroku ps:scale -a feedhub worker=0`。web dyno のメモリ (R14) と DB の接続数を数日見る
   - `config/puma.rb` は `SOLID_QUEUE_IN_PUMA` のとき `solid_queue_mode :async` にしている (プラグインの既定の fork モードはプロセスが増えて R14 になりやすい)。async モードでは Solid Queue の dispatcher・ワーカーのスレッドが Puma と同じプロセスの DB 接続プールを使う
   - そのため worker を 0 にする前に、`config/queue.yml` のスレッド数 (各ワーカーの `threads` の合計と、dispatcher・supervisor の分) を数え、Puma のスレッド数 (`RAILS_MAX_THREADS`) と足した数を `config/database.yml` の `pool` が下回らないようにする。`pool` は今 `RAILS_MAX_THREADS` を見ているので、足りなければ `pool` を別の環境変数で大きくできるようにしてから `SOLID_QUEUE_IN_PUMA` を設定する。Heroku Postgres のプランの接続数の上限にも収まるか確かめる
7. 影モードを止め (`launchctl bootout gui/$(id -u)/app.kairan.feeeed.fetcher-shadow`)、dispatcher の Worker と Hyperdrive を削除する。`dispatcher/` と `fetcher/src/shadow.rs`・`dispatcher_client.rs` の削除は別の PR で行う

巻き戻し: `ROLLOUT_PERCENT=0`、`heroku ps:scale -a feedhub worker=1`、`SOLID_QUEUE_IN_PUMA` を外す。
