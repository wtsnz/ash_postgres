# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.RelationshipPathsTest do
  @moduledoc """
  Aggregates and filters over a relationship path authorize every resource on it, the way
  loading the path does, on AshPostgres.

  An event's orders link it to customers, and an actor can only read visible orders. Event A has
  a visible order from Ann, and hidden orders from Cara and Dan. Event B has visible orders from
  Ann, Bob and Cara. Through the orders an actor can only reach Ann from event A: by the plain path
  `[:orders, :customer]`, the `many_to_many :buyers` (through `Order`), and the
  `has_many :customers, through: [:orders, :customer]`. Customers named "Hidden" can't be read.

  Ash core has the same tests on ETS; these cover the SQL that AshSql generates for aggregates
  (lateral joins, with the join resource's query joined in for a `many_to_many`) and filters.
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

  defmodule Customer do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer,
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table("relationship_paths_customers")
      repo(AshPostgres.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    relationships do
      has_many(:tags, AshPostgres.Test.RelationshipPathsTest.Tag, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end

    policies do
      policy action_type(:read) do
        authorize_if(expr(name != "Hidden"))
      end

      policy action_type(:create) do
        authorize_if(always())
      end
    end
  end

  defmodule Tag do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer,
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table("relationship_paths_tags")
      repo(AshPostgres.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    relationships do
      belongs_to(:customer, Customer, public?: true, attribute_writable?: true)
    end

    actions do
      defaults([:read, create: :*])
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end
  end

  defmodule Order do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer,
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table("relationship_paths_orders")
      repo(AshPostgres.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:visible, :boolean, allow_nil?: false, default: true, public?: true)
    end

    relationships do
      belongs_to(:event, AshPostgres.Test.RelationshipPathsTest.Event,
        public?: true,
        attribute_writable?: true
      )

      belongs_to(:customer, Customer, public?: true, attribute_writable?: true)
    end

    actions do
      defaults([:read, create: :*])
      read(:all_orders)
    end

    policies do
      policy action_type(:read) do
        authorize_if(expr(visible == true))
      end

      policy action_type(:create) do
        authorize_if(always())
      end
    end
  end

  defmodule Event do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer,
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table("relationship_paths_events")
      repo(AshPostgres.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
    end

    relationships do
      has_many(:orders, Order, public?: true)
      has_many(:orders_by_action, Order, public?: true, read_action: :all_orders)

      many_to_many :buyers, Customer do
        public?(true)
        through(Order)
        join_relationship(:orders)
        source_attribute_on_join_resource(:event_id)
        destination_attribute_on_join_resource(:customer_id)
      end

      # Customers named like the event's title.
      many_to_many :namesake_buyers, Customer do
        public?(true)
        through(Order)
        join_relationship(:orders)
        source_attribute_on_join_resource(:event_id)
        destination_attribute_on_join_resource(:customer_id)
        filter(expr(name == parent(title)))
      end

      has_many(:customers, Customer, through: [:orders, :customer], public?: true)
    end

    aggregates do
      list(:order_customer_names, [:orders, :customer], :name, public?: true)

      exists :has_order_customer_cara, [:orders, :customer] do
        public?(true)
        filter(expr(name == "Cara"))
      end

      list(:order_by_action_customer_names, [:orders_by_action, :customer], :name, public?: true)

      count(:buyer_count, :buyers, public?: true)
      list(:buyer_names, :buyers, :name, public?: true)

      first :last_buyer_name, :buyers, :name do
        public?(true)
        sort(name: :desc)
      end

      exists :has_buyer_cara, :buyers do
        public?(true)
        filter(expr(name == "Cara"))
      end

      count(:namesake_buyer_count, :namesake_buyers, public?: true)

      count(:customer_count, :customers, public?: true)
      list(:customer_names, :customers, :name, public?: true)

      first :last_customer_name, :customers, :name do
        public?(true)
        sort(name: :desc)
      end

      exists :has_customer_cara, :customers do
        public?(true)
        filter(expr(name == "Cara"))
      end

      list(:customer_tags, [:customers, :tags], :name, public?: true)
      list(:buyer_tags, [:buyers, :tags], :name, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end
  end

  # Ratings and children with `hidden: true` can't be read.
  defmodule Rating do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer,
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table("relationship_paths_ratings")
      repo(AshPostgres.TestRepo)
    end

    attributes do
      attribute(:id, :integer, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:child_id, :integer, public?: true)
      attribute(:hidden, :boolean, allow_nil?: false, default: false, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end

    policies do
      policy action_type(:read) do
        authorize_if(expr(hidden == false))
      end

      policy action_type(:create) do
        authorize_if(always())
      end
    end
  end

  defmodule Child do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer,
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table("relationship_paths_children")
      repo(AshPostgres.TestRepo)
    end

    attributes do
      attribute(:id, :integer, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:parent_id, :integer, public?: true)
      attribute(:label, :string, public?: true)
      attribute(:hidden, :boolean, allow_nil?: false, default: false, public?: true)
    end

    relationships do
      has_many(:ratings, Rating, destination_attribute: :child_id)
    end

    aggregates do
      count(:rating_count, :ratings)
    end

    actions do
      defaults([:read, create: :*])
      read(:all_children)
    end

    policies do
      policy action_type(:read) do
        authorize_if(expr(hidden == false))
      end

      policy action_type(:create) do
        authorize_if(always())
      end
    end
  end

  defmodule Parent do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer,
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table("relationship_paths_parents")
      repo(AshPostgres.TestRepo)
    end

    attributes do
      attribute(:id, :integer, primary_key?: true, allow_nil?: false, public?: true)
    end

    relationships do
      has_many(:children, Child, destination_attribute: :parent_id)
      has_many(:read_children, Child, destination_attribute: :parent_id, read_action: :read)
    end

    aggregates do
      count(:child_count, :children)
      count(:all_read_children_count, :read_children, read_action: :all_children)
    end

    actions do
      defaults([:read, create: :*])
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end
  end

  # The join resource of a many_to_many, in the tenant's schema.
  defmodule TenantOrder do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer,
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table("relationship_paths_tenant_orders")
      repo(AshPostgres.TestRepo)
    end

    multitenancy do
      strategy(:context)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:visible, :boolean, allow_nil?: false, default: true, public?: true)
      attribute(:event_id, :uuid, public?: true)
      attribute(:customer_id, :uuid, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end

    policies do
      policy action_type(:read) do
        authorize_if(expr(visible == true))
      end

      policy action_type(:create) do
        authorize_if(always())
      end
    end
  end

  defmodule TenantEvent do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer,
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table("relationship_paths_events")
      repo(AshPostgres.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    relationships do
      has_many(:tenant_orders, TenantOrder, public?: true, destination_attribute: :event_id)

      many_to_many :buyers, Customer do
        public?(true)
        through(TenantOrder)
        join_relationship(:tenant_orders)
        source_attribute_on_join_resource(:event_id)
        destination_attribute_on_join_resource(:customer_id)
      end
    end

    aggregates do
      count(:buyer_count, :buyers, public?: true)
      list(:buyer_names, :buyers, :name, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end
  end

  @actor [authorize?: true, actor: %{id: 1}]

  defp customer(name), do: Ash.create!(Customer, %{name: name}, authorize?: false)

  defp order(event, customer, visible?) do
    Ash.create!(Order, %{event_id: event.id, customer_id: customer.id, visible: visible?},
      authorize?: false
    )
  end

  # Event A: Ann's order is visible, Cara's and Dan's aren't. Event B: Ann's, Bob's and Cara's are
  # visible.
  defp events do
    a = Ash.create!(Event, %{title: "Cara"}, authorize?: false)
    b = Ash.create!(Event, %{title: "B"}, authorize?: false)
    [ann, bob, cara, dan] = Enum.map(["Ann", "Bob", "Cara", "Dan"], &customer/1)

    order(a, ann, true)
    order(a, cara, false)
    order(a, dan, false)
    order(b, ann, true)
    order(b, bob, true)
    order(b, cara, true)

    {a, b}
  end

  defp event_ids(query, opts \\ @actor), do: query |> Ash.read!(opts) |> Enum.map(& &1.id)

  # Parent 1 has a visible child with one visible and two hidden ratings, and a hidden child.
  # Parent 2 has a visible child.
  defp parents_with_children do
    for id <- [1, 2], do: Ash.create!(Parent, %{id: id}, authorize?: false)

    for child <- [
          %{id: 11, parent_id: 1, label: "high"},
          %{id: 12, parent_id: 1, label: "high", hidden: true},
          %{id: 21, parent_id: 2, label: "low"}
        ],
        do: Ash.create!(Child, child, authorize?: false)

    for rating <- [
          %{id: 1, child_id: 11},
          %{id: 2, child_id: 11, hidden: true},
          %{id: 3, child_id: 11, hidden: true}
        ],
        do: Ash.create!(Rating, rating, authorize?: false)

    :ok
  end

  defp parent_aggregate(name, kind, relationship, query, opts \\ @actor) do
    Parent
    |> Ash.Query.aggregate(name, kind, relationship, query: query)
    |> Ash.Query.sort(:id)
    |> Ash.read!(opts)
    |> Enum.map(&{&1.id, &1.aggregates[name]})
  end

  describe "normal use" do
    test "loading a many_to_many or through relationship authorizes the join resource" do
      {a, _b} = events()
      a = Ash.load!(a, [:buyers, :customers], @actor)

      assert Enum.map(a.buyers, & &1.name) == ["Ann"]
      assert Enum.map(a.customers, & &1.name) == ["Ann"]
    end

    test "an aggregate over a plain path authorizes the resources along it" do
      {a, _b} = events()
      assert Ash.load!(a, :order_customer_names, @actor).order_customer_names == ["Ann"]
    end

    test "filter_input over a plain path or a through relationship authorizes each step" do
      {a, b} = events()

      assert event_ids(Ash.Query.filter_input(Event, %{customers: %{name: %{eq: "Cara"}}})) ==
               [b.id]

      assert event_ids(
               Ash.Query.filter_input(Event, %{orders: %{customer: %{name: %{eq: "Cara"}}}})
             ) == [b.id]

      assert Enum.sort(
               event_ids(Ash.Query.filter_input(Event, %{customers: %{name: %{eq: "Ann"}}}))
             ) == Enum.sort([a.id, b.id])
    end

    test "unauthorized aggregates over a many_to_many or through relationship count every row" do
      {a, _b} = events()

      a =
        Ash.load!(
          a,
          [:buyer_count, :buyer_names, :last_buyer_name, :customer_names, :namesake_buyer_count],
          authorize?: false
        )

      assert a.buyer_count == 3
      assert Enum.sort(a.buyer_names) == ["Ann", "Cara", "Dan"]
      assert a.last_buyer_name == "Dan"
      assert Enum.sort(a.customer_names) == ["Ann", "Cara", "Dan"]
      assert a.namesake_buyer_count == 1
    end

    test "aggregates over a many_to_many or through relationship with readable join rows" do
      {_a, b} = events()

      b =
        Ash.load!(b, [:buyer_count, :buyer_names, :customer_count, :has_buyer_cara], @actor)

      assert b.buyer_count == 3
      assert Enum.sort(b.buyer_names) == ["Ann", "Bob", "Cara"]
      assert b.customer_count == 3
      assert b.has_buyer_cara
    end

    test "loading and filtering by an aggregate authorizes the related records" do
      parents_with_children()

      counts =
        Parent |> Ash.Query.sort(:id) |> Ash.Query.load(:child_count) |> Ash.read!(@actor)

      assert Enum.map(counts, &{&1.id, &1.child_count}) == [{1, 1}, {2, 1}]
      assert Parent |> Ash.Query.filter(child_count > 1) |> Ash.read!(@actor) == []
    end
  end

  describe "a loaded exists aggregate" do
    # AshSql lowered it without the aggregate's join filters.
    test "over a plain path authorizes the resources along it" do
      {a, b} = events()

      refute Ash.load!(a, :has_order_customer_cara, @actor).has_order_customer_cara
      assert Ash.load!(b, :has_order_customer_cara, @actor).has_order_customer_cara
    end
  end

  describe "S-07: aggregates over a many_to_many" do
    test "count" do
      {a, _b} = events()
      assert Ash.load!(a, :buyer_count, @actor).buyer_count == 1
    end

    test "list" do
      {a, _b} = events()
      assert Ash.load!(a, :buyer_names, @actor).buyer_names == ["Ann"]
    end

    test "first" do
      {a, _b} = events()
      assert Ash.load!(a, :last_buyer_name, @actor).last_buyer_name == "Ann"
    end

    test "exists" do
      {a, b} = events()

      refute Ash.load!(a, :has_buyer_cara, @actor).has_buyer_cara
      assert Ash.load!(b, :has_buyer_cara, @actor).has_buyer_cara
    end

    test "with a filter that uses parent/1" do
      {a, _b} = events()
      assert Ash.load!(a, :namesake_buyer_count, @actor).namesake_buyer_count == 0
    end

    test "in a filter" do
      {_a, b} = events()

      assert event_ids(Ash.Query.filter(Event, buyer_count > 1)) == [b.id]
      assert event_ids(Ash.Query.filter_input(Event, %{buyer_count: %{gt: 1}})) == [b.id]
    end

    test "in a sort" do
      {a, b} = events()
      assert event_ids(Ash.Query.sort(Event, buyer_count: :desc)) == [b.id, a.id]
    end

    test "with the join resource in the tenant's schema" do
      Ecto.Adapters.SQL.query!(AshPostgres.TestRepo, """
      CREATE SCHEMA relationship_paths_tenant;
      """)

      Ecto.Adapters.SQL.query!(AshPostgres.TestRepo, """
      CREATE TABLE relationship_paths_tenant.relationship_paths_tenant_orders (
        id uuid PRIMARY KEY,
        visible boolean NOT NULL DEFAULT true,
        event_id uuid,
        customer_id uuid
      )
      """)

      event = Ash.create!(TenantEvent, %{}, authorize?: false)

      for {name, visible?} <- [{"Ann", true}, {"Cara", false}] do
        Ash.create!(
          TenantOrder,
          %{event_id: event.id, customer_id: customer(name).id, visible: visible?},
          authorize?: false,
          tenant: "relationship_paths_tenant"
        )
      end

      opts = Keyword.put(@actor, :tenant, "relationship_paths_tenant")

      assert Enum.map(Ash.load!(event, :buyers, opts).buyers, & &1.name) == ["Ann"]

      event = Ash.load!(event, [:buyer_count, :buyer_names], opts)
      assert event.buyer_count == 1
      assert event.buyer_names == ["Ann"]
    end
  end

  describe "S-07: aggregates over a through relationship" do
    test "count" do
      {a, _b} = events()
      assert Ash.load!(a, :customer_count, @actor).customer_count == 1
    end

    test "list" do
      {a, _b} = events()
      assert Ash.load!(a, :customer_names, @actor).customer_names == ["Ann"]
    end

    test "first" do
      {a, _b} = events()
      assert Ash.load!(a, :last_customer_name, @actor).last_customer_name == "Ann"
    end

    test "exists" do
      {a, b} = events()

      refute Ash.load!(a, :has_customer_cara, @actor).has_customer_cara
      assert Ash.load!(b, :has_customer_cara, @actor).has_customer_cara
    end

    test "in a filter" do
      {_a, b} = events()

      assert event_ids(Ash.Query.filter(Event, customer_count > 1)) == [b.id]
      assert event_ids(Ash.Query.filter_input(Event, %{customer_count: %{gt: 1}})) == [b.id]
    end

    test "in a sort" do
      {a, b} = events()
      assert event_ids(Ash.Query.sort(Event, customer_count: :desc)) == [b.id, a.id]
    end
  end

  describe "S-07: an aggregate continuing past a many_to_many or through relationship" do
    test "authorizes the records it continues from" do
      event = Ash.create!(Event, %{}, authorize?: false)

      for name <- ["Ann", "Hidden"] do
        customer = customer(name)
        Ash.create!(Tag, %{name: name, customer_id: customer.id}, authorize?: false)
        order(event, customer, true)
      end

      event = Ash.load!(event, [:customer_tags, :buyer_tags], @actor)

      assert event.customer_tags == ["Ann"]
      assert event.buyer_tags == ["Ann"]
    end
  end

  describe "N1: a relationship along an aggregate's path with its own read action" do
    test "its read policies apply" do
      {a, _b} = events()

      assert Ash.load!(a, :order_by_action_customer_names, @actor).order_by_action_customer_names ==
               ["Ann"]
    end
  end

  describe "N2: an aggregate read with another action than its relationship's read action" do
    test "a resource aggregate with its own read_action applies the read policies" do
      parents_with_children()

      counts =
        Parent
        |> Ash.Query.sort(:id)
        |> Ash.Query.load(:all_read_children_count)
        |> Ash.read!(@actor)

      assert Enum.map(counts, &{&1.id, &1.all_read_children_count}) == [{1, 1}, {2, 1}]
    end

    test "an aggregate with a query for another action applies the read policies" do
      parents_with_children()
      query = Ash.Query.for_read(Child, :all_children)

      assert parent_aggregate(:all_count, :count, :read_children, query) == [{1, 1}, {2, 1}]
    end
  end

  describe "S-19" do
    test "an aggregate in another aggregate's query filter applies the read policies" do
      parents_with_children()
      query = Ash.Query.filter(Child, rating_count > 1)

      assert parent_aggregate(:well_rated, :count, :children, query) == [{1, 0}, {2, 0}]
    end
  end
end
