# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.TestRepo.Migrations.AddWriteTenantScopingTable do
  @moduledoc """
  Table for `AshPostgres.Test.WriteTenantScopingTest`: an attribute-multitenant resource with
  client-generated primary keys, a tenant-scoped identity and an `all_tenants?` identity.
  """
  use Ecto.Migration

  def up do
    create table(:write_tenant_scoping_notes, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:shop_id, :text, null: false)
      add(:slug, :text)
      add(:code, :text)
      add(:body, :text)
      add(:secret, :text)
    end

    create(
      unique_index(:write_tenant_scoping_notes, [:shop_id, :slug],
        name: "write_tenant_scoping_notes_slug_index"
      )
    )

    create(
      unique_index(:write_tenant_scoping_notes, [:code],
        name: "write_tenant_scoping_notes_global_code_index"
      )
    )
  end

  def down do
    drop(table(:write_tenant_scoping_notes))
  end
end
