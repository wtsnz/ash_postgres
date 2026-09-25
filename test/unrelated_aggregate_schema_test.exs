# SPDX-FileCopyrightText: 2026 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.UnrelatedAggregateSchemaTest do
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
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      repo(AshPostgres.TestRepo)
      table("schema_reports")
      schema("aggregate_reports")
      migrate?(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:author_name, :string, public?: true)
      attribute(:inserted_at, :utc_datetime, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule PublicReport do
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      repo(AshPostgres.TestRepo)
      table("schema_reports")
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
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      repo(AshPostgres.TestRepo)
      table("schema_reports")
      schema("aggregate_reports")
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

  defmodule AttributeReport do
    use Ash.Resource, domain: Domain, data_layer: AshPostgres.DataLayer

    postgres do
      repo(AshPostgres.TestRepo)
      table("attribute_reports")
      schema("aggregate_reports")
      migrate?(false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:tenant_id)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:author_name, :string, public?: true)
      attribute(:tenant_id, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])

      read :all_tenants do
        multitenancy(:bypass)
      end
    end
  end

  defmodule PublicProfile do
    use Ash.Resource, domain: Domain, data_layer: AshPostgres.DataLayer

    postgres do
      repo(AshPostgres.TestRepo)
      table("schema_profiles")
      migrate?(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule TenantProfile do
    use Ash.Resource, domain: Domain, data_layer: AshPostgres.DataLayer

    postgres do
      repo(AshPostgres.TestRepo)
      table("schema_profiles")
      migrate?(false)
    end

    multitenancy do
      strategy(:context)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule Profile do
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      repo(AshPostgres.TestRepo)
      table("schema_profiles")
      schema("aggregate_profiles")
      migrate?(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end

    aggregates do
      first :latest_report, Report, :title do
        filter(expr(author_name == parent(name)))
        sort(inserted_at: :desc)
      end

      exists :has_report, Report do
        filter(expr(author_name == parent(name)))
      end

      exists :has_tenant_report, TenantReport do
        filter(expr(author_name == parent(name)))
      end

      exists :has_attribute_report, AttributeReport do
        filter(expr(author_name == parent(name)))
      end

      first :any_tenant_first_report, AttributeReport, :title do
        read_action(:all_tenants)
        sort(title: :asc)
      end

      first :bypassing_first_report, AttributeReport, :title do
        multitenancy(:bypass)
        sort(title: :asc)
      end

      exists :has_any_tenant_report, AttributeReport do
        read_action(:all_tenants)
        filter(expr(author_name == parent(name)))
      end

      exists :has_nested_attribute_report, Report do
        filter(
          expr(
            author_name == parent(name) and
              exists(AttributeReport, author_name == parent(author_name))
          )
        )
      end

      exists :has_nested_tenant_report, TenantReport do
        filter(
          expr(author_name == parent(name) and exists(TenantProfile, name == parent(author_name)))
        )
      end
    end

    calculations do
      calculate(
        :inline_latest_report,
        :string,
        expr(
          first(Report,
            field: :title,
            query: [filter: expr(author_name == parent(name)), sort: [inserted_at: :desc]]
          )
        )
      )
    end
  end

  setup do
    for schema <- [
          "aggregate_profiles",
          "aggregate_reports",
          "aggregate_override",
          "aggregate_tenant"
        ] do
      TestRepo.query!(~s(CREATE SCHEMA "#{schema}"))
    end

    for schema <- ["aggregate_profiles", "aggregate_override", "aggregate_tenant", "public"] do
      TestRepo.query!("""
      CREATE TABLE "#{schema}".schema_profiles (id uuid PRIMARY KEY, name text)
      """)
    end

    for schema <- ["aggregate_reports", "aggregate_override", "aggregate_tenant", "public"] do
      TestRepo.query!("""
      CREATE TABLE "#{schema}".schema_reports (
        id uuid PRIMARY KEY, title text, author_name text, inserted_at timestamp
      )
      """)
    end

    TestRepo.query!("""
    CREATE TABLE aggregate_reports.attribute_reports (
      id uuid PRIMARY KEY, title text, author_name text, tenant_id text
    )
    """)

    Ash.create!(Profile, %{name: "Alice"})
    Ash.create!(Profile, %{name: "Bob"})

    for {title, author_name, inserted_at} <- [
          {"Earlier report", "Alice", ~U[2026-01-01 12:00:00Z]},
          {"Latest report", "Alice", ~U[2026-01-02 12:00:00Z]},
          {"Other author's report", "Carol", ~U[2026-01-03 12:00:00Z]}
        ] do
      Ash.create!(Report, %{title: title, author_name: author_name, inserted_at: inserted_at})
    end

    :ok
  end

  test "inline first uses the target schema, parent filter, and sort" do
    assert [%{inline_latest_report: "Latest report"}, %{inline_latest_report: nil}] =
             Profile
             |> Ash.Query.sort(:name)
             |> Ash.Query.load(:inline_latest_report)
             |> Ash.read!()

    assert [%{name: "Alice"}] =
             Profile
             |> Ash.Query.filter(inline_latest_report == "Latest report")
             |> Ash.read!()
  end

  test "named first uses the target schema" do
    assert [%{latest_report: "Latest report"}, %{latest_report: nil}] =
             Profile
             |> Ash.Query.sort(:name)
             |> Ash.Query.load(:latest_report)
             |> Ash.read!()
  end

  test "a same-named table in the source schema does not affect first or exists" do
    TestRepo.query!("""
    CREATE TABLE aggregate_profiles.schema_reports
      (LIKE aggregate_reports.schema_reports INCLUDING ALL)
    """)

    Report
    |> Ash.Changeset.for_create(:create, %{title: "Wrong schema", author_name: "Bob"})
    |> Ash.Changeset.set_context(%{data_layer: %{schema: "aggregate_profiles"}})
    |> Ash.create!()

    assert [%{name: "Alice", inline_latest_report: "Latest report"}] =
             Profile
             |> Ash.Query.filter(exists(Report, author_name == parent(name)))
             |> Ash.Query.load(:inline_latest_report)
             |> Ash.read!()
  end

  test "unrelated exists expressions use the target schema" do
    assert [%{name: "Alice"}] =
             Profile
             |> Ash.Query.filter(exists(Report, author_name == parent(name)))
             |> Ash.read!()
  end

  test "named exists aggregates use the target schema when loaded" do
    assert [%{has_report: true}, %{has_report: false}] =
             Profile
             |> Ash.Query.sort(:name)
             |> Ash.Query.load(:has_report)
             |> Ash.read!()
  end

  test "named exists aggregates use the target schema when filtered" do
    assert [%{name: "Alice"}] =
             Profile
             |> Ash.Query.filter(has_report)
             |> Ash.Query.sort(:name)
             |> Ash.read!()
  end

  test "unrelated count uses the target schema" do
    assert [%{aggregates: %{reports: 2}}, %{aggregates: %{reports: 0}}] =
             Profile
             |> Ash.Query.sort(:name)
             |> Ash.Query.aggregate(:reports, :count, Report,
               query: [filter: expr(author_name == parent(name))]
             )
             |> Ash.read!()
  end

  test "targets without a schema use the repository default prefix" do
    Ash.create!(PublicReport, %{title: "Public report", author_name: "Alice"})

    assert [%{calculations: %{report: "Public report"}}] =
             Profile
             |> Ash.Query.filter(exists(PublicReport, author_name == parent(name)))
             |> Ash.Query.calculate(
               :report,
               :string,
               expr(
                 first(PublicReport,
                   field: :title,
                   query: [filter: expr(author_name == parent(name))]
                 )
               )
             )
             |> Ash.read!()
  end

  test "source schema overrides do not become target schema overrides" do
    Profile
    |> Ash.Changeset.for_create(:create, %{name: "Alice"})
    |> Ash.Changeset.set_context(%{data_layer: %{schema: "aggregate_override"}})
    |> Ash.create!()

    assert [%{inline_latest_report: "Latest report"}] =
             Profile
             |> Ash.Query.set_context(%{data_layer: %{schema: "aggregate_override"}})
             |> Ash.Query.filter(has_report)
             |> Ash.Query.load(:inline_latest_report)
             |> Ash.read!()
  end

  test "first preserves an explicit schema on the target query" do
    Report
    |> Ash.Changeset.for_create(:create, %{title: "Overridden report", author_name: "Alice"})
    |> Ash.Changeset.set_context(%{data_layer: %{schema: "aggregate_override"}})
    |> Ash.create!()

    target_query =
      Report
      |> Ash.Query.new()
      |> Ash.Query.set_context(%{data_layer: %{schema: "aggregate_override"}})

    assert [%{calculations: %{report: "Overridden report"}}] =
             Profile
             |> Ash.Query.filter(name == "Alice")
             |> Ash.Query.calculate(
               :report,
               :string,
               expr(first(Report, field: :title, query: ^target_query))
             )
             |> Ash.read!()
  end

  test "first and exists preserve the tenant schema over the target's declared schema" do
    Ash.create!(TenantReport, %{title: "Tenant report", author_name: "Alice"},
      tenant: "aggregate_tenant"
    )

    assert [%{calculations: %{report: "Tenant report"}}] =
             Profile
             |> Ash.Query.set_tenant("aggregate_tenant")
             |> Ash.Query.filter(exists(TenantReport, author_name == parent(name)))
             |> Ash.Query.calculate(
               :report,
               :string,
               expr(
                 first(TenantReport,
                   field: :title,
                   query: [filter: expr(author_name == parent(name))]
                 )
               )
             )
             |> Ash.read!()
  end

  test "first preserves an explicit target tenant when the source has a different tenant" do
    Ash.create!(TenantReport, %{title: "Target tenant report", author_name: "Alice"},
      tenant: "aggregate_tenant"
    )

    target_query = Ash.Query.set_tenant(TenantReport, "aggregate_tenant")

    assert [%{calculations: %{report: "Target tenant report"}}] =
             Profile
             |> Ash.Query.set_tenant("aggregate_override")
             |> Ash.Query.filter(name == "Alice")
             |> Ash.Query.calculate(
               :report,
               :string,
               expr(first(TenantReport, field: :title, query: ^target_query))
             )
             |> Ash.read!()
  end

  test "default-schema sources read first and exists from the target schema" do
    Ash.create!(PublicProfile, %{name: "Alice"})
    Ash.create!(PublicProfile, %{name: "Bob"})

    assert [%{name: "Alice", calculations: %{report: "Latest report"}}] =
             PublicProfile
             |> Ash.Query.filter(exists(Report, author_name == parent(name)))
             |> Ash.Query.calculate(
               :report,
               :string,
               expr(
                 first(Report,
                   field: :title,
                   query: [filter: expr(author_name == parent(name)), sort: [inserted_at: :desc]]
                 )
               )
             )
             |> Ash.read!()
  end

  test "tenant sources do not redirect non-tenant targets to tenant decoys" do
    Ash.create!(TenantProfile, %{name: "Alice"}, tenant: "aggregate_tenant")
    Ash.create!(TenantProfile, %{name: "Bob"}, tenant: "aggregate_tenant")

    for name <- ["Alice", "Bob"] do
      Ash.create!(TenantReport, %{title: "Tenant decoy", author_name: name},
        tenant: "aggregate_tenant"
      )
    end

    assert [%{name: "Alice", calculations: %{report: "Latest report"}}] =
             TenantProfile
             |> Ash.Query.set_tenant("aggregate_tenant")
             |> Ash.Query.filter(exists(Report, author_name == parent(name)))
             |> Ash.Query.calculate(
               :report,
               :string,
               expr(
                 first(Report,
                   field: :title,
                   query: [filter: expr(author_name == parent(name)), sort: [inserted_at: :desc]]
                 )
               )
             )
             |> Ash.read!()
  end

  test "first converts an integer source tenant to a schema prefix" do
    TestRepo.query!(~s(CREATE SCHEMA "868"))

    TestRepo.query!(
      ~s|CREATE TABLE "868".schema_reports (id uuid PRIMARY KEY, title text, author_name text)|
    )

    Ash.create!(TenantReport, %{title: "Integer tenant report", author_name: "Alice"},
      tenant: "868"
    )

    assert [%{calculations: %{report: "Integer tenant report"}}] =
             Profile
             |> Ash.Query.set_tenant(868)
             |> Ash.Query.filter(name == "Alice")
             |> Ash.Query.calculate(
               :report,
               :string,
               expr(
                 first(TenantReport,
                   field: :title,
                   query: [filter: expr(author_name == parent(name))]
                 )
               )
             )
             |> Ash.read!()
  end

  test "filtering by a tenant exists aggregate only returns matching source rows" do
    Ash.create!(TenantReport, %{title: "Tenant report", author_name: "Alice"},
      tenant: "aggregate_tenant"
    )

    assert [%{name: "Alice"}] =
             Profile
             |> Ash.Query.set_tenant("aggregate_tenant")
             |> Ash.Query.filter(has_tenant_report)
             |> Ash.read!()
  end

  test "first passes attribute tenancy through a non-tenant target to nested exists" do
    Ash.create!(AttributeReport, %{title: "Tenant A report", author_name: "Alice"}, tenant: "a")

    Ash.create!(AttributeReport, %{title: "Other tenant report", author_name: "Carol"},
      tenant: "b"
    )

    assert [%{calculations: %{report: "Latest report"}}] =
             Profile
             |> Ash.Query.set_tenant("a")
             |> Ash.Query.filter(name == "Alice")
             |> Ash.Query.calculate(
               :report,
               :string,
               expr(
                 first(Report,
                   field: :title,
                   query: [
                     filter: expr(exists(AttributeReport, author_name == parent(author_name))),
                     sort: [inserted_at: :desc]
                   ]
                 )
               )
             )
             |> Ash.read!()
  end

  test "a filtered exists aggregate passes attribute tenancy to nested exists" do
    Ash.create!(AttributeReport, %{title: "Tenant A report", author_name: "Alice"}, tenant: "a")

    Ash.create!(AttributeReport, %{title: "Other tenant report", author_name: "Carol"},
      tenant: "b"
    )

    Ash.create!(Profile, %{name: "Carol"})

    assert [%{name: "Alice"}] =
             Profile
             |> Ash.Query.set_tenant("a")
             |> Ash.Query.filter(has_nested_attribute_report)
             |> Ash.read!()
  end

  test "first applies attribute tenancy to its target" do
    Ash.create!(AttributeReport, %{title: "Tenant A report", author_name: "Alice"}, tenant: "a")

    Ash.create!(AttributeReport, %{title: "Other tenant report", author_name: "Alice"},
      tenant: "b"
    )

    Ash.create!(AttributeReport, %{title: "Other tenant report", author_name: "Bob"}, tenant: "b")

    assert [
             %{name: "Alice", calculations: %{report: "Tenant A report"}},
             %{name: "Bob", calculations: %{report: nil}}
           ] =
             Profile
             |> Ash.Query.set_tenant("a")
             |> Ash.Query.sort(:name)
             |> Ash.Query.calculate(
               :report,
               :string,
               expr(
                 first(AttributeReport,
                   field: :title,
                   query: [filter: expr(author_name == parent(name)), sort: [title: :asc]]
                 )
               )
             )
             |> Ash.read!()
  end

  test "filtering by an attribute-tenant exists aggregate excludes other tenants" do
    Ash.create!(AttributeReport, %{title: "Tenant A report", author_name: "Alice"}, tenant: "a")
    Ash.create!(AttributeReport, %{title: "Other tenant report", author_name: "Bob"}, tenant: "b")

    assert [%{name: "Alice"}] =
             Profile
             |> Ash.Query.set_tenant("a")
             |> Ash.Query.filter(has_attribute_report)
             |> Ash.read!()
  end

  describe "tenancy bypass" do
    setup do
      Ash.create!(AttributeReport, %{title: "Tenant A report", author_name: "Alice"}, tenant: "a")

      Ash.create!(AttributeReport, %{title: "Another tenant's report", author_name: "Bob"},
        tenant: "b"
      )

      :ok
    end

    test "first respects a target read action that bypasses tenancy" do
      assert [%{any_tenant_first_report: "Another tenant's report"}] =
               Profile
               |> Ash.Query.set_tenant("a")
               |> Ash.Query.filter(name == "Alice")
               |> Ash.Query.load(:any_tenant_first_report)
               |> Ash.read!()
    end

    test "first respects an aggregate that bypasses tenancy" do
      assert [%{bypassing_first_report: "Another tenant's report"}] =
               Profile
               |> Ash.Query.set_tenant("a")
               |> Ash.Query.filter(name == "Alice")
               |> Ash.Query.load(:bypassing_first_report)
               |> Ash.read!()
    end

    test "filtering by exists respects a target read action that bypasses tenancy" do
      assert [%{name: "Alice"}, %{name: "Bob"}] =
               Profile
               |> Ash.Query.set_tenant("a")
               |> Ash.Query.filter(has_any_tenant_report)
               |> Ash.Query.sort(:name)
               |> Ash.read!()
    end

    test "a count that bypasses tenancy reads every tenant" do
      assert [%{aggregates: %{reports: 2}}] =
               Profile
               |> Ash.Query.set_tenant("a")
               |> Ash.Query.filter(name == "Alice")
               |> Ash.Query.aggregate(:reports, :count, AttributeReport, multitenancy: :bypass)
               |> Ash.read!()
    end
  end

  test "nested exists inside first retains the source tenant" do
    Ash.create!(TenantProfile, %{name: "Alice"}, tenant: "aggregate_tenant")

    Ash.create!(TenantReport, %{title: "Tenant report", author_name: "Alice"},
      tenant: "aggregate_tenant"
    )

    assert [%{calculations: %{report: "Tenant report"}}] =
             TenantProfile
             |> Ash.Query.set_tenant("aggregate_tenant")
             |> Ash.Query.calculate(
               :report,
               :string,
               expr(
                 first(TenantReport,
                   field: :title,
                   query: [filter: expr(exists(TenantReport, title == "Tenant report"))]
                 )
               )
             )
             |> Ash.read!()
  end

  test "nested first inside first retains the source tenant" do
    Ash.create!(TenantProfile, %{name: "Alice"}, tenant: "aggregate_tenant")

    Ash.create!(TenantReport, %{title: "Tenant report", author_name: "Alice"},
      tenant: "aggregate_tenant"
    )

    assert [%{calculations: %{report: "Tenant report"}}] =
             TenantProfile
             |> Ash.Query.set_tenant("aggregate_tenant")
             |> Ash.Query.calculate(
               :report,
               :string,
               expr(
                 first(TenantReport,
                   field: :title,
                   query: [filter: expr(first(TenantReport, field: :title) == "Tenant report")]
                 )
               )
             )
             |> Ash.read!()
  end

  test "nested tenant queries without a declared schema do not fall back to public" do
    Ash.create!(TenantProfile, %{name: "Alice"}, tenant: "aggregate_tenant")

    assert [%{calculations: %{name: "Alice"}}] =
             TenantProfile
             |> Ash.Query.set_tenant("aggregate_tenant")
             |> Ash.Query.calculate(
               :name,
               :string,
               expr(
                 first(TenantProfile,
                   field: :name,
                   query: [filter: expr(exists(TenantProfile, name == "Alice"))]
                 )
               )
             )
             |> Ash.read!()
  end

  test "a non-tenant first target passes the tenant to nested expressions" do
    Ash.create!(TenantProfile, %{name: "Alice"}, tenant: "aggregate_tenant")

    assert [%{calculations: %{report: "Other author's report"}}] =
             TenantProfile
             |> Ash.Query.set_tenant("aggregate_tenant")
             |> Ash.Query.calculate(
               :report,
               :string,
               expr(
                 first(Report,
                   field: :title,
                   query: [
                     filter: expr(exists(TenantProfile, name == "Alice")),
                     sort: [inserted_at: :desc]
                   ]
                 )
               )
             )
             |> Ash.read!()
  end

  test "nested exists inside a filtered exists aggregate retains the source tenant" do
    Ash.create!(TenantProfile, %{name: "Alice"}, tenant: "aggregate_tenant")

    Ash.create!(TenantReport, %{title: "Tenant report", author_name: "Alice"},
      tenant: "aggregate_tenant"
    )

    assert [%{name: "Alice"}] =
             Profile
             |> Ash.Query.set_tenant("aggregate_tenant")
             |> Ash.Query.filter(has_nested_tenant_report)
             |> Ash.read!()
  end

  test "nested exists inside an exists expression retains the source tenant" do
    Ash.create!(TenantProfile, %{name: "Alice"}, tenant: "aggregate_tenant")

    Ash.create!(TenantReport, %{title: "Tenant report", author_name: "Alice"},
      tenant: "aggregate_tenant"
    )

    assert [%{name: "Alice"}] =
             TenantProfile
             |> Ash.Query.set_tenant("aggregate_tenant")
             |> Ash.Query.filter(
               exists(
                 TenantReport,
                 author_name == parent(name) and exists(TenantProfile, name == "Alice")
               )
             )
             |> Ash.read!()
  end

  test "first passes an explicit target tenant to nested expressions" do
    Ash.create!(TenantReport, %{title: "Source report", author_name: "Alice"},
      tenant: "aggregate_override"
    )

    Ash.create!(TenantReport, %{title: "Target report", author_name: "Alice"},
      tenant: "aggregate_tenant"
    )

    target_query =
      TenantReport
      |> Ash.Query.set_tenant("aggregate_tenant")
      |> Ash.Query.filter(exists(TenantReport, title == "Target report"))

    assert [%{calculations: %{report: "Target report"}}] =
             Profile
             |> Ash.Query.set_tenant("aggregate_override")
             |> Ash.Query.filter(name == "Alice")
             |> Ash.Query.calculate(
               :report,
               :string,
               expr(first(TenantReport, field: :title, query: ^target_query))
             )
             |> Ash.read!()
  end
end
