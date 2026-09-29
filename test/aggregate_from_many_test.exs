# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.AggregateFromManyTest do
  use AshPostgres.RepoCase, async: false
  require Ash.Query

  defmodule Comment do
    use Ash.Resource,
      domain: AshPostgres.AggregateFromManyTest.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("comments")
      repo(AshPostgres.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:post_id, :uuid)
      attribute(:likes, :integer)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Post do
    use Ash.Resource,
      domain: AshPostgres.AggregateFromManyTest.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("posts")
      repo(AshPostgres.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end

    relationships do
      has_one :top_comment, Comment do
        destination_attribute(:post_id)
        sort(likes: :desc)
        from_many?(true)
      end

      has_one :second_comment, Comment do
        destination_attribute(:post_id)
        sort(likes: :desc)
        offset(1)
      end
    end

    aggregates do
      count(:top_comment_count, :top_comment)
      sum(:top_comment_likes, :top_comment, :likes)
      count(:second_comment_count, :second_comment)
      sum(:second_comment_likes, :second_comment, :likes)

      count :matching_top_comment_count, :top_comment do
        filter(expr(likes == 2))
      end

      first :matching_top_comment_likes, :top_comment, :likes do
        filter(expr(likes == 2))
      end

      list :matching_top_comment_likes_list, :top_comment, :likes do
        filter(expr(likes == 2))
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Post)
      resource(Comment)
    end
  end

  setup do
    post = Ash.Seed.seed!(%AshPostgres.Test.Post{title: "from_many aggregate"})

    for likes <- [2, 3] do
      Ash.Seed.seed!(%AshPostgres.Test.Comment{
        post_id: post.id,
        title: "comment",
        likes: likes
      })
    end

    %{query: Post |> Ash.Query.filter(id == ^post.id)}
  end

  test "loading from_many selects the highest-ranked comment", %{query: query} do
    assert %{top_comment: %{likes: 3}} =
             query |> Ash.Query.load(:top_comment) |> Ash.read_one!()
  end

  test "count aggregates only the selected from_many row", %{query: query} do
    assert %{top_comment_count: 1} =
             query |> Ash.Query.load(:top_comment_count) |> Ash.read_one!()
  end

  test "sum aggregates only the selected from_many row", %{query: query} do
    assert %{top_comment_likes: 3} =
             query |> Ash.Query.load(:top_comment_likes) |> Ash.read_one!()
  end

  test "selects one row per parent and preserves empty relationships", %{query: query} do
    original = Ash.read_one!(query)
    other = Ash.Seed.seed!(%AshPostgres.Test.Post{title: "other parent"})
    empty = Ash.Seed.seed!(%AshPostgres.Test.Post{title: "empty parent"})

    for likes <- [7, 9] do
      Ash.Seed.seed!(%AshPostgres.Test.Comment{
        post_id: other.id,
        title: "other comment",
        likes: likes
      })
    end

    ids = [original.id, other.id, empty.id]

    results =
      Post
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.load([:top_comment_count, :top_comment_likes])
      |> Ash.read!()
      |> Map.new(&{&1.id, {&1.top_comment_count, &1.top_comment_likes}})

    assert results == %{original.id => {1, 3}, other.id => {1, 9}, empty.id => {0, nil}}
  end

  test "aggregate filters apply after selecting the from_many row", %{query: query} do
    assert %{
             matching_top_comment_count: 0,
             matching_top_comment_likes: nil,
             matching_top_comment_likes_list: []
           } =
             query
             |> Ash.Query.load([
               :matching_top_comment_count,
               :matching_top_comment_likes,
               :matching_top_comment_likes_list
             ])
             |> Ash.read_one!()
  end

  test "offset selects one row after skipping higher-ranked comments", %{query: query} do
    post = Ash.read_one!(query)

    Ash.Seed.seed!(%AshPostgres.Test.Comment{
      post_id: post.id,
      title: "lowest comment",
      likes: 1
    })

    assert %{second_comment: %{likes: 2}} =
             query |> Ash.Query.load(:second_comment) |> Ash.read_one!()

    assert %{second_comment_count: 1, second_comment_likes: 2} =
             query
             |> Ash.Query.load([:second_comment_count, :second_comment_likes])
             |> Ash.read_one!()
  end
end
