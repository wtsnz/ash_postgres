# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.ReadTenantScopingTest do
  @moduledoc """
  Reads that AshPostgres lowers itself, with Ash core applying attribute tenancy to queries lowered
  without running their read action. See the Ash read spike's `ReadTenantScopingTest`.
  """
  use AshPostgres.RepoCase, async: false

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
      uuid_primary_key(:id, writable?: true, public?: true)
      attribute(:shop_id, :string, allow_nil?: false, public?: true)
      attribute(:body, :string, public?: true)
    end

    relationships do
      has_many :peers, __MODULE__ do
        no_attributes?(true)
        public?(true)
      end
    end

    actions do
      defaults([:read, create: [:body]])

      read :bypass do
        multitenancy(:bypass)
      end
    end
  end

  setup do
    Ash.create!(Note, %{body: "a's"}, tenant: "a")
    Ash.create!(Note, %{body: "b's"}, tenant: "b")
    :ok
  end

  defp peers(query) do
    query
    |> Ash.Query.load(peers: Note |> Ash.Query.sort(:body) |> Ash.Query.limit(1))
    |> Ash.read!()
    |> Enum.map(&{&1.shop_id, Enum.map(&1.peers, fn peer -> peer.body end)})
    |> Enum.sort()
  end

  test "a lateral load within a tenant" do
    assert peers(Ash.Query.for_read(Note, :read, %{}, tenant: "a")) == [{"a", ["a's"]}]
  end

  test "a lateral load from a :bypass read keeps every parent's related records" do
    # The related query is scoped to tenant a; each parent, in either tenant, gets a's note.
    assert peers(Ash.Query.for_read(Note, :bypass, %{}, tenant: "a")) ==
             [{"a", ["a's"]}, {"b", ["a's"]}]
  end
end
