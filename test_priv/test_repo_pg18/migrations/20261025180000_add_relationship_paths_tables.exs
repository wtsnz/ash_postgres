# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.TestRepo.Migrations.AddRelationshipPathsTables do
  @moduledoc """
  Tables for `AshPostgres.Test.RelationshipPathsTest`: events linked to customers through orders
  (a join resource), customers' tags, and parents with children and ratings.
  """
  use Ecto.Migration

  def up do
    create table(:relationship_paths_events, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:title, :text)
    end

    create table(:relationship_paths_customers, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:name, :text)
    end

    create table(:relationship_paths_orders, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:visible, :boolean, null: false, default: true)
      add(:event_id, :uuid)
      add(:customer_id, :uuid)
    end

    create table(:relationship_paths_tags, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:name, :text)
      add(:customer_id, :uuid)
    end

    create table(:relationship_paths_parents, primary_key: false) do
      add(:id, :bigint, null: false, primary_key: true)
    end

    create table(:relationship_paths_children, primary_key: false) do
      add(:id, :bigint, null: false, primary_key: true)
      add(:parent_id, :bigint)
      add(:label, :text)
      add(:hidden, :boolean, null: false, default: false)
    end

    create table(:relationship_paths_ratings, primary_key: false) do
      add(:id, :bigint, null: false, primary_key: true)
      add(:child_id, :bigint)
      add(:hidden, :boolean, null: false, default: false)
    end
  end

  def down do
    drop(table(:relationship_paths_ratings))
    drop(table(:relationship_paths_children))
    drop(table(:relationship_paths_parents))
    drop(table(:relationship_paths_tags))
    drop(table(:relationship_paths_orders))
    drop(table(:relationship_paths_customers))
    drop(table(:relationship_paths_events))
  end
end
