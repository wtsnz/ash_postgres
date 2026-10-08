# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.UpdateLockKeyColumnsTest do
  @moduledoc """
  An update that AshPostgres runs as `UPDATE … FROM (subquery)` locks the subquery's rows as
  strongly as the `UPDATE` will: `FOR UPDATE` when it changes a key column, and
  `FOR NO KEY UPDATE` otherwise.

  `AshPostgres.Test.KeyedProduct` has a column for each way a unique index can name it. For
  each column, these tests check the lock AshPostgres chooses, and that PostgreSQL agrees: a
  plain `UPDATE` of a key column blocks `FOR KEY SHARE`, and of any other column doesn't.
  """
  use AshPostgres.RepoCase, async: false

  require Ash.Query

  alias AshPostgres.Test.{Author, KeyedProduct}
  alias AshPostgres.TestNoSandboxRepo

  @no_sandbox %{data_layer: %{repo: TestNoSandboxRepo}}

  # {attribute, column, new value, whether PostgreSQL treats the column as a key, how}
  @columns [
    {:stock, "stock", 5, false, "in no index"},
    {:rank, "rank", 2, false, "in a non-unique directed index"},
    {:label, "label", "L-2", false, "only in a unique expression index"},
    {:shop_id, "shop_id", :uuid, true, "a directed atom field of a unique index"},
    {:code, "sku", "A-2", true, "a different column name, named by a directed field"},
    {:barcode, "barcode", "B-2", true, "a string field of a unique index"},
    {:serial, "serial", "S-2", true, "a directed string field of a unique index"},
    {:handle, "handle", "h-2", true, "an identity key"},
    {:id, "id", :uuid, true, "the primary key"}
  ]

  setup do
    owner = Ash.create!(Author, %{first_name: "owner"})
    %{owner: owner, product: create_product(owner)}
  end

  defp create_product(owner, attrs \\ %{}, context \\ %{}) do
    KeyedProduct
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          shop_id: Ash.UUID.generate(),
          code: "A-1",
          barcode: "B-1",
          serial: "S-1",
          label: "L-1",
          handle: "h-1",
          rank: 1,
          stock: 1,
          owner_id: owner.id
        },
        attrs
      )
    )
    |> Ash.Changeset.set_context(context)
    |> Ash.create!()
  end

  # Rows committed outside the sandbox, for tests that need two real connections.
  defp committed_owner do
    Author
    |> Ash.Changeset.for_create(:create, %{first_name: "committed owner"})
    |> Ash.Changeset.set_context(@no_sandbox)
    |> Ash.create!()
  end

  # Unique values, so a committed row doesn't wait on the sandbox's uncommitted one.
  defp committed_attrs do
    n = System.unique_integer([:positive])
    %{code: "C-#{n}", barcode: "CB-#{n}", serial: "CS-#{n}", label: "CL-#{n}", handle: "ch-#{n}"}
  end

  defp delete_committed_rows do
    TestNoSandboxRepo.query!("DELETE FROM keyed_products")
    TestNoSandboxRepo.query!("DELETE FROM authors WHERE first_name = 'committed owner'")
  end

  defp new_value(:uuid), do: Ash.UUID.generate()
  defp new_value(value), do: value

  defp lock(true), do: "FOR UPDATE"
  defp lock(false), do: "FOR NO KEY UPDATE"

  # The `UPDATE` (or `DELETE`) statement that `fun` runs.
  defp statement_sql(statement \\ "UPDATE", fun) do
    parent = self()
    handler = "update-lock-key-columns-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:ash_postgres, :test_repo, :query],
      fn _, _, %{query: query}, _ ->
        if self() == parent and String.starts_with?(query, statement) do
          send(parent, {:statement_sql, query})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    assert_received {:statement_sql, sql}
    sql
  end

  defp assert_lock(sql, lock) do
    assert sql =~ "#{lock} OF"

    if lock == "FOR UPDATE" do
      refute sql =~ "NO KEY"
    end
  end

  defp limited(product) do
    KeyedProduct
    |> Ash.Query.filter(id == ^product.id)
    |> Ash.Query.limit(1)
  end

  defp stored(product), do: Ash.get!(KeyedProduct, product.id)

  describe "the lock chosen for each updated column" do
    for {attribute, _column, value, key?, how} <- @columns do
      test "#{attribute} (#{how}) takes #{if key?, do: "FOR UPDATE", else: "FOR NO KEY UPDATE"}",
           %{product: product} do
        value = new_value(unquote(value))

        sql =
          statement_sql(fn ->
            product
            |> limited()
            |> Ash.bulk_update!(:update, %{unquote(attribute) => value}, strategy: :atomic)
          end)

        assert_lock(sql, lock(unquote(key?)))
        assert [%{unquote(attribute) => ^value}] = Ash.read!(KeyedProduct)
      end
    end

    # A plain `UPDATE` of a key column takes `FOR UPDATE`, which conflicts with
    # `FOR KEY SHARE`; of any other column, `FOR NO KEY UPDATE`, which doesn't. So this checks
    # the table above against PostgreSQL itself.
    for {_attribute, column, value, key?, how} <- @columns do
      test "PostgreSQL treats #{column} (#{how}) as #{if key?, do: "a key", else: "not a key"}",
           %{} do
        on_exit(&delete_committed_rows/0)

        product = create_product(committed_owner(), committed_attrs(), @no_sandbox)

        value =
          if unquote(value) == :uuid,
            do: Ecto.UUID.dump!(Ash.UUID.generate()),
            else: unquote(value)

        id = Ecto.UUID.dump!(product.id)
        test = self()

        writer =
          Task.async(fn ->
            TestNoSandboxRepo.transaction(fn ->
              TestNoSandboxRepo.query!(
                "UPDATE keyed_products SET #{unquote(column)} = $1 WHERE id = $2",
                [value, id]
              )

              send(test, :written)

              receive do
                :done -> TestNoSandboxRepo.rollback(:done)
              end
            end)
          end)

        assert_receive :written, 5_000

        probe =
          TestNoSandboxRepo.query(
            "SELECT 1 FROM keyed_products WHERE id = $1 FOR KEY SHARE NOWAIT",
            [id]
          )

        send(writer.pid, :done)
        Task.await(writer, 5_000)

        if unquote(key?) do
          assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} = probe
        else
          assert {:ok, _} = probe
        end
      end
    end
  end

  describe "updates through the subquery" do
    test "a code interface called with an id", %{product: product} do
      sql = statement_sql(fn -> KeyedProduct.restock!(product.id, 5) end)

      assert_lock(sql, "FOR NO KEY UPDATE")
      assert stored(product).stock == 6
    end

    test "a query with a limit", %{product: product} do
      sql =
        statement_sql(fn ->
          product |> limited() |> Ash.bulk_update!(:restock, %{amount: 5}, strategy: :atomic)
        end)

      assert_lock(sql, "FOR NO KEY UPDATE")
      assert stored(product).stock == 6
    end

    test "a query with an offset", %{owner: owner, product: product} do
      second =
        create_product(owner, %{
          code: "A-9",
          barcode: "B-9",
          serial: "S-9",
          label: "L-9",
          handle: "h-9"
        })

      sql =
        statement_sql(fn ->
          KeyedProduct
          |> Ash.Query.sort(:barcode)
          |> Ash.Query.offset(1)
          |> Ash.bulk_update!(:restock, %{amount: 5}, strategy: :atomic)
        end)

      assert_lock(sql, "FOR NO KEY UPDATE")
      assert {stored(product).stock, stored(second).stock} == {1, 6}
    end

    test "a distinct query", %{product: product} do
      sql =
        statement_sql(fn ->
          KeyedProduct
          |> Ash.Query.filter(id == ^product.id)
          |> Ash.Query.distinct(:code)
          |> Ash.bulk_update!(:restock, %{amount: 5}, strategy: :atomic)
        end)

      assert_lock(sql, "FOR NO KEY UPDATE")
      assert stored(product).stock == 6
    end

    test "atomics that join a relationship", %{product: product} do
      sql =
        statement_sql(fn ->
          KeyedProduct
          |> Ash.Query.filter(id == ^product.id)
          |> Ash.bulk_update!(:restock_if_owned, %{amount: 5}, strategy: :atomic)
        end)

      assert_lock(sql, "FOR NO KEY UPDATE")
      assert stored(product).stock == 6
    end

    test "atomics that use exists", %{product: product} do
      sql =
        statement_sql(fn ->
          KeyedProduct
          |> Ash.Query.filter(id == ^product.id)
          |> Ash.bulk_update!(:restock_if_owner_exists, %{amount: 5}, strategy: :atomic)
        end)

      assert_lock(sql, "FOR NO KEY UPDATE")
      assert stored(product).stock == 6
    end

    test "an update of a record whose atomics join a relationship", %{product: product} do
      sql =
        statement_sql(fn ->
          Ash.update!(product, %{amount: 5}, action: :restock_if_owned)
        end)

      assert_lock(sql, "FOR NO KEY UPDATE")
      assert stored(product).stock == 6
    end

    test "an atomic change to a key column, through a code interface called with an id",
         %{product: product} do
      sql = statement_sql(fn -> KeyedProduct.retag!(product.id, "X") end)

      assert_lock(sql, "FOR UPDATE")
      assert stored(product).code == "X-A-1"
    end

    test "an atomic change to a key column that joins a relationship", %{product: product} do
      sql =
        statement_sql(fn ->
          KeyedProduct
          |> Ash.Query.filter(id == ^product.id)
          |> Ash.bulk_update!(:retag_if_owned, %{code: "X"}, strategy: :atomic)
        end)

      assert_lock(sql, "FOR UPDATE")
      assert stored(product).code == "X-A-1"
    end

    test "a destroy over a query with a limit takes FOR UPDATE", %{product: product} do
      sql =
        statement_sql("DELETE", fn ->
          product |> limited() |> Ash.bulk_destroy!(:destroy, %{}, strategy: :atomic)
        end)

      assert_lock(sql, "FOR UPDATE")
      assert Ash.read!(KeyedProduct) == []
    end

    test "a query's own lock is kept", %{product: product} do
      sql =
        statement_sql(fn ->
          AshPostgres.TestRepo.transaction(fn ->
            product
            |> limited()
            |> Ash.Query.lock("FOR SHARE")
            |> Ash.bulk_update!(:restock, %{amount: 5}, strategy: :atomic)
          end)
        end)

      assert sql =~ "FOR SHARE OF"
      refute sql =~ "FOR NO KEY UPDATE"
      assert stored(product).stock == 6
    end
  end

  # Two updates of the same row at once, on real connections: each waits for the other's
  # lock and computes from the committed row, so neither change is lost.
  describe "concurrent updates through the subquery" do
    setup do
      on_exit(&delete_committed_rows/0)
      %{product: create_product(committed_owner(), committed_attrs(), @no_sandbox)}
    end

    defp concurrently(fun) do
      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            send(parent, {:ready, self()})
            receive do: (:go -> :ok)
            fun.()
          end)
        end

      pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
      Enum.each(pids, &send(&1, :go))
      Task.await_many(tasks, 10_000)
    end

    defp stored_no_sandbox(product) do
      Ash.get!(KeyedProduct, product.id, context: @no_sandbox)
    end

    test "of a non-key column, through a code interface called with an id", %{product: product} do
      concurrently(fn -> KeyedProduct.restock!(product.id, 5, context: @no_sandbox) end)

      assert stored_no_sandbox(product).stock == 11
    end

    test "of a key column, through a code interface called with an id", %{product: product} do
      concurrently(fn -> KeyedProduct.retag!(product.id, "X", context: @no_sandbox) end)

      assert stored_no_sandbox(product).code == "X-X-#{product.code}"
    end
  end
end
