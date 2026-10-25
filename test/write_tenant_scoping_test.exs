# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.WriteTenantScopingTest do
  @moduledoc """
  Every write path given a tenant only writes records in that tenant, on AshPostgres.

  The tests that cross tenants start from a note that belongs to shop "b", held by code acting
  for shop "a". `Ash.update(b_note, ..., tenant: "a")` is refused, so every other way of writing
  it should be too. Ash core has the same tests on ETS; these cover the SQL the data layer
  generates: per-record `UPDATE`/`DELETE` for the `:stream` strategy, and
  `ON CONFLICT ... DO UPDATE ... WHERE` for upserts.
  """
  use AshPostgres.RepoCase, async: false

  require Ash.Query

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defmodule Note do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("write_tenant_scoping_notes")
      repo(AshPostgres.TestRepo)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:shop_id)
    end

    attributes do
      # Client-generated primary keys (for example offline sync), upserted on the primary key.
      uuid_primary_key(:id, writable?: true, public?: true)
      attribute(:shop_id, :string, allow_nil?: false, public?: true)
      attribute(:slug, :string, public?: true)
      attribute(:code, :string, public?: true)
      attribute(:body, :string, public?: true)
      attribute(:secret, :string, public?: true)
    end

    identities do
      identity(:slug, [:slug])
      identity(:global_code, [:code], all_tenants?: true)
    end

    actions do
      defaults([:read, create: [:id, :slug, :code, :body, :secret]])

      read :global do
        multitenancy(:allow_global)
      end

      update :update do
        primary?(true)
        accept([:body])
      end

      update :update_nonatomic do
        accept([:body])
        require_atomic?(false)
        change(fn changeset, _ -> changeset end)
      end

      destroy :destroy do
        primary?(true)
      end

      destroy :archive do
        soft?(true)
        change(set_attribute(:body, "archived"))
      end

      create :save do
        accept([:id, :body])
        upsert?(true)
        upsert_fields([:body])
      end

      create :save_by_slug do
        accept([:slug, :body])
        upsert?(true)
        upsert_identity(:slug)
        upsert_fields([:body])
      end

      create :save_by_code do
        accept([:code, :body])
        upsert?(true)
        upsert_identity(:global_code)
        upsert_fields([:body])
      end
    end
  end

  defmodule Scope do
    @moduledoc false
    defstruct [:tenant]

    defimpl Ash.Scope.ToOpts do
      def get_actor(_), do: :error
      def get_tenant(%{tenant: tenant}), do: {:ok, tenant}
      def get_context(_), do: :error
      def get_tracer(_), do: :error
      def get_authorize?(_), do: :error
    end
  end

  defp note!(tenant, attrs \\ %{}) do
    Ash.create!(Note, Map.merge(%{body: "original", secret: "#{tenant}'s secret"}, attrs),
      tenant: tenant
    )
  end

  # The note's row as stored, read straight from the table.
  defp stored(%Note{id: id}) do
    %{rows: rows} =
      AshPostgres.TestRepo.query!(
        "SELECT shop_id, body FROM write_tenant_scoping_notes WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    case rows do
      [[shop_id, body]] -> {shop_id, body}
      [] -> :gone
    end
  end

  describe "within a tenant" do
    for strategy <- [:atomic, :atomic_batches, :stream] do
      test "bulk update and destroy of records, #{strategy}" do
        note = note!("a")

        assert %{status: :success} =
                 Ash.bulk_update([note], :update_nonatomic, %{body: "changed"},
                   tenant: "a",
                   strategy: [unquote(strategy), :stream],
                   return_errors?: true
                 )

        assert stored(note) == {"a", "changed"}

        assert %{status: :success} =
                 Ash.bulk_destroy([note], :archive, %{},
                   tenant: "a",
                   strategy: unquote(strategy),
                   return_errors?: true
                 )

        assert stored(note) == {"a", "archived"}

        assert %{status: :success} =
                 Ash.bulk_destroy([note], :destroy, %{},
                   tenant: "a",
                   strategy: unquote(strategy),
                   return_errors?: true
                 )

        assert stored(note) == :gone
      end
    end

    test "update_many with :stream" do
      note = note!("a")

      assert %{status: :success} =
               Ash.update_many([{note, %{body: "changed"}}], Note, :update,
                 tenant: "a",
                 strategy: :stream,
                 return_errors?: true
               )

      assert stored(note) == {"a", "changed"}
    end

    test "single updates and destroys, with a tenant or a scope" do
      note = note!("a")
      assert {:ok, _} = Ash.update(note, %{body: "changed"}, tenant: "a")
      assert {:ok, _} = Ash.update(note, %{body: "scoped"}, scope: %Scope{tenant: "a"})
      assert stored(note) == {"a", "scoped"}

      assert :ok =
               note |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: "a") |> Ash.destroy()

      assert stored(note) == :gone
    end

    test "upserts on the primary key, single and bulk" do
      id = Ash.UUID.generate()

      assert {:ok, _} = Ash.create(Note, %{id: id, body: "first"}, action: :save, tenant: "a")
      assert {:ok, _} = Ash.create(Note, %{id: id, body: "second"}, action: :save, tenant: "a")
      assert stored(%Note{id: id}) == {"a", "second"}

      assert %{status: :success} =
               Ash.bulk_create([%{id: id, body: "bulk"}], Note, :save,
                 tenant: "a",
                 return_errors?: true
               )

      assert stored(%Note{id: id}) == {"a", "bulk"}
    end

    test "a bulk upsert with records for two tenants updates each in its own tenant" do
      a_note = note!("a")
      b_note = note!("b")

      # Each record's tenant comes from its input. AshPostgres uses one upsert condition per
      # batch, so the two tenants' records must not share one.
      assert %{status: :success} =
               Ash.bulk_create(
                 [%{id: a_note.id, body: "a's update"}, %{id: b_note.id, body: "b's update"}],
                 Note,
                 :save,
                 tenant: "a",
                 return_errors?: true,
                 transform_changeset: fn changeset ->
                   if Ash.Changeset.get_attribute(changeset, :id) == b_note.id do
                     changeset
                     |> Ash.Changeset.set_tenant("b")
                     |> Ash.Changeset.force_change_attribute(:shop_id, "b")
                   else
                     changeset
                   end
                 end
               )

      assert stored(a_note) == {"a", "a's update"}
      assert stored(b_note) == {"b", "b's update"}
    end

    test "upserts on a tenant-scoped identity and an all_tenants? identity" do
      note = note!("a", %{slug: "s", code: "c"})

      assert {:ok, _} =
               Ash.create(Note, %{slug: "s", body: "by slug"}, action: :save_by_slug, tenant: "a")

      assert stored(note) == {"a", "by slug"}

      assert {:ok, _} =
               Ash.create(Note, %{code: "c", body: "by code"}, action: :save_by_code, tenant: "a")

      assert stored(note) == {"a", "by code"}
    end
  end

  describe "another tenant's record" do
    for strategy <- [:atomic, :atomic_batches, :stream] do
      test "bulk update, destroy and soft destroy, #{strategy}" do
        b_note = note!("b")

        Ash.bulk_update([b_note], :update, %{body: "changed by a"},
          tenant: "a",
          strategy: unquote(strategy)
        )

        assert stored(b_note) == {"b", "original"}

        Ash.bulk_destroy([b_note], :archive, %{}, tenant: "a", strategy: unquote(strategy))
        assert stored(b_note) == {"b", "original"}

        Ash.bulk_destroy([b_note], :destroy, %{}, tenant: "a", strategy: unquote(strategy))
        assert stored(b_note) == {"b", "original"}
      end
    end

    test "a non-atomic action falling back to :stream" do
      b_note = note!("b")

      Ash.bulk_update([b_note], :update_nonatomic, %{body: "changed by a"},
        tenant: "a",
        strategy: [:atomic, :stream]
      )

      assert stored(b_note) == {"b", "original"}
    end

    test "update_many with :stream" do
      b_note = note!("b")

      Ash.update_many([{b_note, %{body: "changed by a"}}], Note, :update,
        tenant: "a",
        strategy: :stream
      )

      assert stored(b_note) == {"b", "original"}
    end

    test "a record read without a tenant, with :stream" do
      b_note = note!("b")

      [global_b_note] =
        Note
        |> Ash.Query.for_read(:global)
        |> Ash.Query.filter(id == ^b_note.id)
        |> Ash.read!()

      Ash.bulk_update([global_b_note], :update_nonatomic, %{body: "changed by a"},
        tenant: "a",
        strategy: :stream
      )

      assert stored(b_note) == {"b", "original"}
    end

    test "a destroy changeset built for the tenant" do
      b_note = note!("b")

      assert {:error, _} =
               b_note |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: "a") |> Ash.destroy()

      assert stored(b_note) == {"b", "original"}
    end

    test "an update or destroy with a scope" do
      b_note = note!("b")
      scope = %Scope{tenant: "a"}
      assert {:error, _} = Ash.update(b_note, %{body: "changed by a"}, scope: scope)
      assert {:error, _} = Ash.destroy(b_note, scope: scope)
      assert stored(b_note) == {"b", "original"}
    end

    test "an upsert on the primary key" do
      b_note = note!("b")

      result = Ash.create(Note, %{id: b_note.id, body: "from a"}, action: :save, tenant: "a")

      assert {:error, _} = result
      assert stored(b_note) == {"b", "original"}
    end

    test "a bulk upsert on the primary key" do
      b_note = note!("b")

      result =
        Ash.bulk_create([%{id: b_note.id, body: "from a"}], Note, :save,
          tenant: "a",
          return_records?: true
        )

      refute Enum.any?(result.records || [], &(&1.secret == "b's secret"))
      assert stored(b_note) == {"b", "original"}
    end

    test "an upsert on an all_tenants? identity" do
      # The code is unique across tenants, but only tenant b may update b's note.
      b_note = note!("b", %{code: "c"})
      Ash.create(Note, %{code: "c", body: "from a"}, action: :save_by_code, tenant: "a")
      assert stored(b_note) == {"b", "original"}
    end
  end
end
