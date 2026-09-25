# SPDX-FileCopyrightText: 2026 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.SubqueryPrefixTest do
  @moduledoc """
  Subqueries that read another resource's table choose their schema in this
  order: an explicit schema on the target query, the tenant for context
  multitenancy, the resource's configured schema, then the repo default.

  Each test puts the expected rows in one schema and decoy rows in another.
  """
  use AshPostgres.RepoCase, async: false

  require Ash.Query
  import Ash.Expr

  defmodule Domain do
    use Ash.Domain

    resources do
      allow_unregistered?(true)
    end
  end

  defmodule Report do
    use Ash.Resource, domain: Domain, data_layer: AshPostgres.DataLayer

    postgres do
      repo(AshPostgres.TestRepo)
      table("prefix_reports")
      schema("prefix_declared")
      migrate?(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:author_name, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule TenantReport do
    use Ash.Resource, domain: Domain, data_layer: AshPostgres.DataLayer

    postgres do
      repo(AshPostgres.TestRepo)
      table("prefix_reports")
      schema("prefix_declared")
      migrate?(false)
    end

    multitenancy do
      strategy(:context)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:author_name, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule ModifiedReport do
    use Ash.Resource, domain: Domain, data_layer: AshPostgres.DataLayer

    postgres do
      repo(AshPostgres.TestRepo)
      table("prefix_reports")
      schema("prefix_declared")
      migrate?(false)
    end

    multitenancy do
      strategy(:context)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:author_name, :string, public?: true)
    end

    actions do
      read :read do
        primary?(true)
        multitenancy(:allow_global)

        modify_query(fn _ash_query, query ->
          {:ok, Ecto.Query.put_query_prefix(query, "prefix_override")}
        end)
      end
    end
  end

  defmodule TenantLink do
    use Ash.Resource, domain: Domain, data_layer: AshPostgres.DataLayer

    postgres do
      repo(AshPostgres.TestRepo)
      table("prefix_links")
      schema("prefix_declared")
      migrate?(false)
    end

    multitenancy do
      strategy(:context)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:author_name, :string, public?: true)
      attribute(:report_id, :uuid, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule TenantAuthor do
    use Ash.Resource, domain: Domain, data_layer: AshPostgres.DataLayer

    postgres do
      repo(AshPostgres.TestRepo)
      table("prefix_authors")
      migrate?(false)
    end

    multitenancy do
      strategy(:context)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    relationships do
      has_many :reports, TenantReport do
        source_attribute(:name)
        destination_attribute(:author_name)
        public?(true)
      end

      many_to_many :linked_reports, TenantReport do
        through(TenantLink)
        source_attribute(:name)
        source_attribute_on_join_resource(:author_name)
        destination_attribute_on_join_resource(:report_id)
        public?(true)
      end
    end

    actions do
      defaults([:read, create: :*])
    end

    aggregates do
      count(:report_count, :reports)
      first(:first_report_title, :reports, :title)
      count(:linked_count, :linked_reports)
    end
  end

  defmodule Author do
    use Ash.Resource, domain: Domain, data_layer: AshPostgres.DataLayer

    postgres do
      repo(AshPostgres.TestRepo)
      table("prefix_authors")
      migrate?(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    relationships do
      has_many :override_reports, Report do
        source_attribute(:name)
        destination_attribute(:author_name)
        relationship_context(%{data_layer: %{schema: "prefix_override"}})
        public?(true)
      end
    end

    actions do
      defaults([:read, create: :*])
    end

    aggregates do
      count(:override_report_count, :override_reports)
    end
  end

  setup do
    for schema <- ["prefix_declared", "prefix_tenant", "prefix_override", "868"] do
      TestRepo.query!(~s(CREATE SCHEMA "#{schema}"))

      TestRepo.query!(
        ~s|CREATE TABLE "#{schema}".prefix_reports (id uuid PRIMARY KEY, title text, author_name text)|
      )
    end

    for schema <- ["public", "prefix_tenant", "868"] do
      TestRepo.query!(
        ~s|CREATE TABLE "#{schema}".prefix_authors (id uuid PRIMARY KEY, name text)|
      )
    end

    for {schema, titles} <- [
          {"prefix_declared", ["Declared decoy"]},
          {"prefix_tenant", ["Tenant A", "Tenant B"]},
          {"prefix_override", ["Override A", "Override B", "Override C"]},
          {"868", ["Integer tenant"]}
        ],
        title <- titles do
      TestRepo.query!(
        ~s|INSERT INTO "#{schema}".prefix_reports VALUES (gen_random_uuid(), $1, 'Alice')|,
        [title]
      )
    end

    for schema <- ["prefix_declared", "prefix_tenant", "prefix_override", "868"] do
      TestRepo.query!(
        ~s|CREATE TABLE "#{schema}".prefix_links (id uuid PRIMARY KEY, author_name text, report_id uuid)|
      )

      TestRepo.query!(
        ~s|INSERT INTO "#{schema}".prefix_links SELECT gen_random_uuid(), author_name, id FROM "#{schema}".prefix_reports|
      )
    end

    Ash.create!(TenantAuthor, %{name: "Alice"}, tenant: "prefix_tenant")
    Ash.create!(TenantAuthor, %{name: "Alice"}, tenant: "868")
    Ash.create!(Author, %{name: "Alice"})

    :ok
  end

  describe "context multitenancy with a configured schema" do
    test "relationship aggregates read the tenant schema" do
      assert [%{report_count: 2, first_report_title: title}] =
               TenantAuthor
               |> Ash.Query.set_tenant("prefix_tenant")
               |> Ash.Query.load([:report_count, :first_report_title])
               |> Ash.read!()

      assert title in ["Tenant A", "Tenant B"]
    end

    test "relationship filters read the tenant schema" do
      assert [%{name: "Alice"}] =
               TenantAuthor
               |> Ash.Query.set_tenant("prefix_tenant")
               |> Ash.Query.filter(reports.title == "Tenant A")
               |> Ash.read!()

      assert [] =
               TenantAuthor
               |> Ash.Query.set_tenant("prefix_tenant")
               |> Ash.Query.filter(reports.title == "Declared decoy")
               |> Ash.read!()
    end

    test "relationship exists reads the tenant schema" do
      assert [%{name: "Alice"}] =
               TenantAuthor
               |> Ash.Query.set_tenant("prefix_tenant")
               |> Ash.Query.filter(exists(reports, title == "Tenant B"))
               |> Ash.read!()
    end

    test "unrelated count reads the tenant schema" do
      assert [%{aggregates: %{reports: 2}}] =
               Author
               |> Ash.Query.set_tenant("prefix_tenant")
               |> Ash.Query.aggregate(:reports, :count, TenantReport,
                 query: [filter: expr(author_name == parent(name))]
               )
               |> Ash.read!()
    end

    test "many-to-many aggregates read the tenant schema" do
      assert [%{linked_count: 2}] =
               TenantAuthor
               |> Ash.Query.set_tenant("prefix_tenant")
               |> Ash.Query.load(:linked_count)
               |> Ash.read!()
    end

    test "a limited source query keeps the tenant for many-to-many aggregates" do
      assert [%{linked_count: 2, report_count: 2}] =
               TenantAuthor
               |> Ash.Query.set_tenant("prefix_tenant")
               |> Ash.Query.limit(1)
               |> Ash.Query.load([:linked_count, :report_count])
               |> Ash.read!()
    end

    test "an integer tenant becomes a schema prefix for many-to-many aggregates" do
      assert [%{linked_count: 1}] =
               TenantAuthor
               |> Ash.Query.set_tenant(868)
               |> Ash.Query.load(:linked_count)
               |> Ash.read!()
    end

    test "an integer tenant becomes a schema prefix" do
      assert [%{report_count: 1}] =
               TenantAuthor
               |> Ash.Query.set_tenant(868)
               |> Ash.Query.load(:report_count)
               |> Ash.read!()
    end
  end

  describe "the target query's own prefix" do
    test "a prefix set by the target's read action is kept" do
      assert ["Override A", "Override B", "Override C"] =
               ModifiedReport |> Ash.read!() |> Enum.map(& &1.title) |> Enum.sort()

      assert [%{name: "Alice"}] =
               Author
               |> Ash.Query.filter(exists(ModifiedReport, title == "Override A"))
               |> Ash.read!()

      assert [] =
               Author
               |> Ash.Query.filter(exists(ModifiedReport, title == "Declared decoy"))
               |> Ash.read!()
    end

    test "a tenant wins over a schema in the target's context, as in a direct read" do
      target =
        TenantReport
        |> Ash.Query.set_tenant("prefix_tenant")
        |> Ash.Query.set_context(%{data_layer: %{schema: "prefix_override"}})
        |> Ash.Query.sort(:title)

      assert ["Tenant A", "Tenant B"] = target |> Ash.read!() |> Enum.map(& &1.title)

      assert [%{calculations: %{report: "Tenant A"}}] =
               Author
               |> Ash.Query.calculate(
                 :report,
                 :string,
                 expr(first(TenantReport, field: :title, query: ^target))
               )
               |> Ash.read!()
    end
  end

  describe "explicit schemas on the target" do
    test "a relationship's schema context is used" do
      assert [%{override_report_count: 3}] =
               Author
               |> Ash.Query.load(:override_report_count)
               |> Ash.read!()
    end

    test "unrelated count uses a schema set on its query" do
      target =
        Report
        |> Ash.Query.new()
        |> Ash.Query.set_context(%{data_layer: %{schema: "prefix_override"}})

      assert [%{aggregates: %{overridden: 3, declared: 1}}] =
               Author
               |> Ash.Query.aggregate(:overridden, :count, Report, query: target)
               |> Ash.Query.aggregate(:declared, :count, Report)
               |> Ash.read!()
    end
  end
end
