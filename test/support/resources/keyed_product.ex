# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.KeyedProduct do
  @moduledoc false
  # A column for each way a unique index can name it, for the row lock chosen by
  # updates that run through a subquery. See `test/update_lock_key_columns_test.exs`.
  use Ash.Resource,
    domain: AshPostgres.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "keyed_products"
    repo AshPostgres.TestRepo

    custom_indexes do
      # Directed fields, one naming the physical column of `code`.
      index [{:asc, :shop_id}, {:desc, :sku}], unique: true
      # A plain string field.
      index ["barcode"], unique: true
      # A directed string field.
      index [{:desc, "serial"}], unique: true
      # An expression. PostgreSQL doesn't treat expression indexes as keys.
      index ["lower(label)"], unique: true, name: "keyed_products_lower_label_index"
      # Not unique, so not a key.
      index [{:desc, :rank}], unique: false
    end
  end

  identities do
    identity(:unique_handle, [:handle])
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:shop_id, :uuid, public?: true, allow_nil?: false)
    attribute(:code, :string, public?: true, allow_nil?: false, source: :sku)
    attribute(:barcode, :string, public?: true)
    attribute(:serial, :string, public?: true)
    attribute(:label, :string, public?: true)
    attribute(:handle, :string, public?: true)
    attribute(:rank, :integer, public?: true)
    attribute(:stock, :integer, public?: true, allow_nil?: false, default: 0)
  end

  relationships do
    belongs_to(:owner, AshPostgres.Test.Author, public?: true, attribute_writable?: true)
  end

  actions do
    defaults([
      :read,
      :destroy,
      create: [:id, :shop_id, :code, :barcode, :serial, :label, :handle, :rank, :stock, :owner_id],
      update: [:id, :shop_id, :code, :barcode, :serial, :label, :handle, :rank, :stock]
    ])

    update :restock do
      argument(:amount, :integer, allow_nil?: false)
      change(atomic_update(:stock, expr(stock + ^arg(:amount))))
    end

    # Atomics that need a join, or `exists`.
    update :restock_if_owned do
      argument(:amount, :integer, allow_nil?: false)

      change(
        atomic_update(
          :stock,
          expr(if owner.first_name == "owner", do: stock + ^arg(:amount), else: stock)
        )
      )
    end

    update :restock_if_owner_exists do
      argument(:amount, :integer, allow_nil?: false)

      change(
        atomic_update(
          :stock,
          expr(if exists(owner, first_name == "owner"), do: stock + ^arg(:amount), else: stock)
        )
      )
    end

    # Atomics that change a key column.
    update :retag do
      argument(:code, :string, allow_nil?: false)
      change(atomic_update(:code, expr(^arg(:code) <> "-" <> code)))
    end

    update :retag_if_owned do
      argument(:code, :string, allow_nil?: false)

      change(
        atomic_update(
          :code,
          expr(if owner.first_name == "owner", do: ^arg(:code) <> "-" <> code, else: code)
        )
      )
    end
  end

  code_interface do
    define(:restock, args: [:amount])
    define(:retag, args: [:code])
  end
end
