# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.LockedAggregateComment do
  @moduledoc false
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: AshPostgres.Test.LockedAggregateDomain

  postgres do
    table "comments"
    repo AshPostgres.TestNoSandboxRepo
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
    attribute(:likes, :integer, public?: true)
  end

  relationships do
    belongs_to(:post, AshPostgres.Test.LockedAggregatePost, public?: true)
  end

  actions do
    defaults([:read])
  end
end

defmodule AshPostgres.Test.LockedAggregatePost do
  @moduledoc false
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: AshPostgres.Test.LockedAggregateDomain

  postgres do
    table "posts"
    repo AshPostgres.TestNoSandboxRepo
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, source: :title_column)
    attribute(:score, :integer, public?: true)
  end

  relationships do
    has_many(:comments, AshPostgres.Test.LockedAggregateComment, destination_attribute: :post_id)
    belongs_to(:parent_post, __MODULE__, public?: true)
  end

  aggregates do
    sum(:sum_likes, :comments, :likes, default: 0)
    count(:comment_count, :comments)
    exists(:any_comments, :comments)
    first(:first_likes, :comments, :likes)
    list(:likes_list, :comments, :likes)
  end

  calculations do
    calculate(:remaining, :integer, expr(score - sum_likes))
    calculate(:related_score, :integer, expr(parent_post.score))
    calculate(:comments_exist, :boolean, expr(exists(comments, true)))
    calculate(:own_score_plus_one, :integer, expr(score + 1))
  end

  actions do
    defaults([:read, create: [:title, :score, :parent_post_id]])

    read :locked do
      prepare(build(lock: :for_update, load: [:sum_likes, :remaining]))
    end

    read :paged do
      pagination(offset?: true, keyset?: true, required?: false)
    end
  end
end

defmodule AshPostgres.Test.LockedAggregateDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshPostgres.Test.LockedAggregatePost)
    resource(AshPostgres.Test.LockedAggregateComment)
  end
end

defmodule AshPostgres.Test.LockedAggregateConcurrencyTest do
  @moduledoc """
  These tests use real connections. The writer commits only after pg_stat_activity
  confirms the reader is waiting on a lock, rather than relying on a sleep.
  """
  use ExUnit.Case, async: false
  require Ash.Query
  alias AshPostgres.Test.LockedAggregatePost, as: Post
  alias AshPostgres.TestNoSandboxRepo, as: Repo

  setup do
    parent = Ash.create!(Post, %{title: "parent", score: 10}, authorize?: false)

    post =
      Ash.create!(Post, %{title: "locked", score: 100, parent_post_id: parent.id},
        authorize?: false
      )

    on_exit(fn ->
      for id <- [post.id, parent.id] do
        Repo.query!("DELETE FROM posts WHERE id = $1", [Ecto.UUID.dump!(id)])
      end
    end)

    %{post: post, parent: parent}
  end

  defp concurrent_read(post, parent, read, opts \\ []) do
    caller = self()

    writer =
      Task.async(fn ->
        Repo.transaction(fn ->
          Ash.get!(Post, post.id, lock: :for_update, authorize?: false)

          Repo.query!(
            "INSERT INTO comments (id, post_id, likes, title) VALUES ($1,$2,30,'refund')",
            [Ecto.UUID.dump!(Ash.UUID.generate()), Ecto.UUID.dump!(post.id)]
          )

          if opts[:update_parent] do
            Repo.query!("UPDATE posts SET score=20 WHERE id=$1", [Ecto.UUID.dump!(parent.id)])
          end

          if opts[:update_root] do
            Repo.query!("UPDATE posts SET score=110 WHERE id=$1", [Ecto.UUID.dump!(post.id)])
          end

          send(caller, :writer_ready)

          receive do
            :commit -> :ok
          after
            10_000 -> raise "reader never waited"
          end
        end)
      end)

    assert_receive :writer_ready, 5_000

    reader =
      Task.async(fn ->
        Repo.transaction(fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(caller, {:reader_pid, pid})
          read.(post.id)
        end)
      end)

    assert_receive {:reader_pid, pid}, 5_000

    if opts[:no_wait] do
      result = Task.await(reader, 5_000)
      send(writer.pid, :commit)
      Task.await(writer, 5_000)
      result
    else
      try do
        await_lock(pid, System.monotonic_time(:millisecond) + 5_000)
      after
        send(writer.pid, :commit)
      end

      assert {:ok, :ok} = Task.await(writer, 5_000)
      Task.await(reader, 5_000)
    end
  end

  defp await_lock(pid, deadline) do
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1", [pid]).rows do
      [["Lock"]] ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline, "reader did not wait for row lock"
        Process.sleep(10)
        await_lock(pid, deadline)
    end
  end

  for {field, expected} <- [
        sum_likes: 0,
        comment_count: 0,
        any_comments: false,
        first_likes: nil,
        likes_list: [],
        remaining: 100,
        comments_exist: false
      ] do
    @tag :statement_snapshot
    test "same-statement #{field} load keeps the original snapshot", %{post: post, parent: parent} do
      assert {:ok, record} =
               concurrent_read(post, parent, fn id ->
                 Ash.get!(Post, id, lock: :for_update, load: [unquote(field)], authorize?: false)
               end)

      assert Map.fetch!(record, unquote(field)) == unquote(expected)
    end
  end

  @tag :statement_snapshot
  test "relationship expression uses the statement snapshot", %{post: post, parent: parent} do
    assert {:ok, record} =
             concurrent_read(
               post,
               parent,
               fn id ->
                 Ash.get!(Post, id, lock: :for_update, load: [:related_score], authorize?: false)
               end,
               update_parent: true
             )

    assert record.related_score == 10
  end

  @tag :statement_snapshot
  test "a prepared read action uses the statement snapshot for loads", %{
    post: post,
    parent: parent
  } do
    assert {:ok, record} =
             concurrent_read(post, parent, fn id ->
               Post
               |> Ash.Query.for_read(:locked)
               |> Ash.Query.filter(id == ^id)
               |> Ash.read_one!(authorize?: false)
             end)

    assert {record.sum_likes, record.remaining} == {0, 100}
  end

  @tag :statement_snapshot
  test "FOR NO KEY UPDATE also uses the statement snapshot", %{post: post, parent: parent} do
    assert {:ok, record} =
             concurrent_read(post, parent, fn id ->
               Ash.get!(Post, id,
                 lock: "FOR NO KEY UPDATE",
                 load: [:sum_likes],
                 authorize?: false
               )
             end)

    assert record.sum_likes == 0
  end

  test "separate load gets a fresh value", %{post: post, parent: parent} do
    assert {:ok, record} =
             concurrent_read(post, parent, fn id ->
               Post
               |> Ash.get!(id, lock: :for_update, authorize?: false)
               |> Ash.load!([:sum_likes, :remaining], authorize?: false)
             end)

    assert {record.sum_likes, record.remaining} == {30, 70}
  end

  test "relationship load runs after the locked statement", %{post: post, parent: parent} do
    assert {:ok, record} =
             concurrent_read(post, parent, fn id ->
               Ash.get!(Post, id,
                 lock: :for_update,
                 load: [:comments],
                 authorize?: false,
                 context: %{data_layer: %{repo: Repo}}
               )
             end)

    assert Enum.map(record.comments, & &1.likes) == [30]
  end

  test "updated root attributes and calculations use the new root version", %{
    post: post,
    parent: parent
  } do
    assert {:ok, record} =
             concurrent_read(
               post,
               parent,
               fn id ->
                 Ash.get!(Post, id,
                   lock: :for_update,
                   load: [:own_score_plus_one],
                   authorize?: false
                 )
               end,
               update_root: true
             )

    assert {record.score, record.own_score_plus_one} == {110, 111}
  end

  @tag :statement_snapshot
  test "aggregate filter keeps the statement snapshot after waiting", %{
    post: post,
    parent: parent
  } do
    assert {:ok, record} =
             concurrent_read(
               post,
               parent,
               fn id ->
                 Post
                 |> Ash.Query.filter(id == ^id and sum_likes == 0)
                 |> Ash.Query.lock(:for_update)
                 |> Ash.read_one!(authorize?: false)
               end,
               update_root: true
             )

    assert record.score == 110
  end

  @tag :statement_snapshot
  test "exists filter keeps the statement snapshot after waiting", %{post: post, parent: parent} do
    assert {:ok, record} =
             concurrent_read(
               post,
               parent,
               fn id ->
                 Post
                 |> Ash.Query.filter(id == ^id and not exists(comments, true))
                 |> Ash.Query.lock(:for_update)
                 |> Ash.read_one!(authorize?: false)
               end,
               update_root: true
             )

    assert record.score == 110
  end

  test "limit offset and sort select the same rows", %{post: post, parent: parent} do
    assert {:ok, [record]} =
             Repo.transaction(fn ->
               Post
               |> Ash.Query.filter(id in ^[post.id, parent.id])
               |> Ash.Query.sort(:score)
               |> Ash.Query.offset(1)
               |> Ash.Query.limit(1)
               |> Ash.Query.lock(:for_update)
               |> Ash.Query.load(:sum_likes)
               |> Ash.read!(authorize?: false)
             end)

    assert record.id == post.id
  end

  test "offset and keyset pagination return loaded rows", %{post: post, parent: parent} do
    for page <- [[limit: 1, offset: 1], [limit: 1]] do
      assert {:ok, result} =
               Repo.transaction(fn ->
                 Post
                 |> Ash.Query.for_read(:paged)
                 |> Ash.Query.filter(id in ^[post.id, parent.id])
                 |> Ash.Query.sort(:score)
                 |> Ash.Query.lock(:for_update)
                 |> Ash.Query.load(:sum_likes)
                 |> Ash.read!(authorize?: false, page: page)
               end)

      assert length(result.results) == 1
      assert hd(result.results).sum_likes == 0
    end
  end

  test "SKIP LOCKED skips the row", %{post: post, parent: parent} do
    assert {:ok, nil} =
             concurrent_read(
               post,
               parent,
               fn id ->
                 Ash.get!(Post, id,
                   lock: "FOR UPDATE SKIP LOCKED",
                   load: [:sum_likes],
                   authorize?: false,
                   not_found_error?: false
                 )
               end,
               no_wait: true
             )
  end

  test "NOWAIT reports an error without waiting", %{post: post, parent: parent} do
    assert {:error, _} =
             concurrent_read(
               post,
               parent,
               fn id ->
                 Ash.get(Post, id,
                   lock: "FOR UPDATE NOWAIT",
                   load: [:sum_likes],
                   authorize?: false
                 )
               end,
               no_wait: true
             )
  end
end
