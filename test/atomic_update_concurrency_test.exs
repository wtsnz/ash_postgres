# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.AtomicUpdateConcurrencyTest do
  @moduledoc """
  An update whose query has a limit or offset, or whose atomics need a join or `exists`, is
  run as `UPDATE ... FROM (SELECT <new values> ...)`. The subquery has to lock the rows it
  computes from, or an update that waited on a concurrent writer overwrites that writer's
  change with values computed from the row as it was before.

  Real concurrency needs two database connections, so these tests bypass the sandbox.
  """
  use AshPostgres.RepoCase, async: false

  require Ash.Query

  alias AshPostgres.Test.Post
  alias AshPostgres.TestNoSandboxRepo

  @context %{data_layer: %{repo: TestNoSandboxRepo}}

  setup do
    on_exit(fn -> TestNoSandboxRepo.delete_all(Post) end)

    post =
      Post
      |> Ash.Changeset.for_create(:create, %{title: "title", score: 0})
      |> Ash.Changeset.set_context(@context)
      |> Ash.create!()

    %{post: post}
  end

  # Increments the score in a transaction held open until `update` is waiting on it, then
  # commits and returns the score once both writes are done.
  defp score_after_concurrent_increment(post, update) do
    post_after_concurrent_increment(post, update).score
  end

  # The same, returning the stored post, or `nil` if it was deleted.
  defp post_after_concurrent_increment(post, update) do
    during_concurrent_write(
      fn ->
        post
        |> Ash.Changeset.for_update(:increment_score, %{amount: 1})
        |> Ash.Changeset.set_context(@context)
        |> Ash.update!()
      end,
      update
    )

    TestNoSandboxRepo.get(Post, post.id)
  end

  # Runs `write` in a transaction held open until `update` is waiting on it, then commits,
  # and returns once both are done.
  defp during_concurrent_write(write, update) do
    parent = self()

    first =
      Task.async(fn ->
        TestNoSandboxRepo.transaction(fn ->
          write.()
          send(parent, :first_written)

          receive do
            :commit -> :ok
          end
        end)
      end)

    assert_receive :first_written, 5_000

    second = Task.async(update)

    refute Task.yield(second, 300), "the second update should be waiting on the first writer"

    send(first.pid, :commit)

    assert {:ok, :ok} = Task.await(first, 5_000)
    Task.await(second, 5_000)
  end

  test "an update through a code interface given an id keeps a concurrent write", %{post: post} do
    assert score_after_concurrent_increment(post, fn ->
             Post.increment_score!(post.id, 1, context: @context)
           end) == 2
  end

  test "an update over a query with a limit keeps a concurrent write", %{post: post} do
    assert score_after_concurrent_increment(post, fn ->
             Post
             |> Ash.Query.filter(id == ^post.id)
             |> Ash.Query.limit(1)
             |> Ash.bulk_update!(:increment_score, %{amount: 1},
               context: @context,
               strategy: :atomic,
               return_errors?: true
             )
           end) == 2
  end

  test "an update whose atomics read an aggregate keeps a concurrent write", %{post: post} do
    for title <- ["a", "b"] do
      AshPostgres.Test.Comment
      |> Ash.Changeset.for_create(:create, %{title: title, post_id: post.id})
      |> Ash.Changeset.set_context(@context)
      |> Ash.create!()
    end

    assert score_after_concurrent_increment(post, fn ->
             Post
             |> Ash.Query.filter(id == ^post.id)
             |> Ash.bulk_update!(:add_comment_count_to_score, %{},
               context: @context,
               strategy: :atomic,
               return_errors?: true
             )
           end) == 3
  end

  test "an update's lock doesn't block inserting a row that references it", %{post: post} do
    parent = self()

    update =
      Task.async(fn ->
        TestNoSandboxRepo.transaction(fn ->
          Post
          |> Ash.Query.filter(id == ^post.id)
          |> Ash.Query.limit(1)
          |> Ash.bulk_update!(:increment_score, %{amount: 1},
            context: @context,
            strategy: :atomic,
            return_errors?: true
          )

          send(parent, :updated)

          receive do
            :commit -> :ok
          end
        end)
      end)

    assert_receive :updated, 5_000

    # The foreign key check locks the post with `FOR KEY SHARE`, which a plain update's
    # `FOR NO KEY UPDATE` allows and `FOR UPDATE` doesn't.
    insert =
      Task.async(fn ->
        AshPostgres.Test.Comment
        |> Ash.Changeset.for_create(:create, %{title: "a", post_id: post.id})
        |> Ash.Changeset.set_context(@context)
        |> Ash.create!()
      end)

    assert {:ok, _} = Task.yield(insert, 1_000), "the insert should not wait on the update"

    send(update.pid, :commit)
    assert {:ok, :ok} = Task.await(update, 5_000)
  end

  test "an update whose atomics use exists keeps a concurrent write", %{post: post} do
    assert score_after_concurrent_increment(post, fn ->
             Post
             |> Ash.Query.filter(id == ^post.id)
             |> Ash.bulk_update!(:increment_score_unless_commented, %{},
               context: @context,
               strategy: :atomic,
               return_errors?: true
             )
           end) == 2
  end

  # The `UPDATE` (or `DELETE`) statement run by `fun`.
  defp update_sql(statement \\ "UPDATE", fun) do
    parent = self()
    handler = "atomic-update-sql-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:ash_postgres, :test_no_sandbox_repo, :query],
      fn _, _, %{query: query}, _ ->
        if String.starts_with?(query, statement), do: send(parent, {:update_sql, query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    assert_received {:update_sql, sql}
    sql
  end

  defp bulk_update_one(post, action, input) do
    Post
    |> Ash.Query.filter(id == ^post.id)
    |> Ash.Query.limit(1)
    |> Ash.bulk_update!(action, input,
      context: @context,
      strategy: :atomic,
      return_errors?: true
    )
  end

  test "an update of other columns locks with FOR NO KEY UPDATE", %{post: post} do
    sql = update_sql(fn -> bulk_update_one(post, :increment_score, %{amount: 1}) end)

    assert sql =~ "FOR NO KEY UPDATE OF"
  end

  test "an update of a column in a unique index locks with FOR UPDATE", %{post: post} do
    sql = update_sql(fn -> bulk_update_one(post, :append_to_uniq_one, %{}) end)

    assert sql =~ "FOR UPDATE OF"
    refute sql =~ "NO KEY"
    assert TestNoSandboxRepo.get!(Post, post.id).uniq_one == "!"
  end

  # The subquery also selects the rows. PostgreSQL re-checks a row against the subquery's
  # filter after waiting only if the subquery locked it, so without a lock a row that a
  # concurrent write moved out of the filter is still written, even when the new values don't
  # read the row.
  test "an update over a limited query skips a row a concurrent write moved out of its filter",
       %{post: post} do
    post =
      post_after_concurrent_increment(post, fn ->
        Post
        |> Ash.Query.filter(id == ^post.id and score == 0)
        |> Ash.Query.limit(1)
        |> Ash.bulk_update!(:set_title, %{title: "changed"},
          context: @context,
          strategy: :atomic,
          return_errors?: true
        )
      end)

    assert {post.score, post.title} == {1, "title"}
  end

  # Author has no timestamps, so this update's only new value is a constant.
  test "an update setting a constant skips a row a concurrent write moved out of its filter" do
    on_exit(fn -> TestNoSandboxRepo.delete_all(AshPostgres.Test.Author) end)

    author =
      AshPostgres.Test.Author
      |> Ash.Changeset.for_create(:create, %{first_name: "open"})
      |> Ash.Changeset.set_context(@context)
      |> Ash.create!()

    during_concurrent_write(
      fn ->
        author
        |> Ash.Changeset.for_update(:update, %{first_name: "paid"})
        |> Ash.Changeset.set_context(@context)
        |> Ash.update!()
      end,
      fn ->
        AshPostgres.Test.Author
        |> Ash.Query.filter(id == ^author.id and first_name == "open")
        |> Ash.Query.limit(1)
        |> Ash.bulk_update!(:update, %{last_name: "closed"},
          context: @context,
          strategy: :atomic,
          return_errors?: true
        )
      end
    )

    author = TestNoSandboxRepo.get!(AshPostgres.Test.Author, author.id)
    assert {author.first_name, author.last_name} == {"paid", nil}
  end

  test "a destroy over a limited query skips a row a concurrent write moved out of its filter",
       %{post: post} do
    post =
      post_after_concurrent_increment(post, fn ->
        Post
        |> Ash.Query.filter(id == ^post.id and score == 0)
        |> Ash.Query.limit(1)
        |> Ash.bulk_destroy!(:destroy, %{},
          context: @context,
          strategy: :atomic,
          return_errors?: true
        )
      end)

    assert post.score == 1
  end

  test "a destroy over a limited query locks with FOR UPDATE", %{post: post} do
    sql =
      update_sql("DELETE", fn ->
        Post
        |> Ash.Query.filter(id == ^post.id)
        |> Ash.Query.limit(1)
        |> Ash.bulk_destroy!(:destroy, %{}, context: @context, strategy: :atomic)
      end)

    assert sql =~ "FOR UPDATE OF"
    refute sql =~ "NO KEY"
  end
end
