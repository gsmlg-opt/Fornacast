defmodule ForgeReleases.ReleaseTest do
  use ExUnit.Case, async: true

  alias ForgeReleases.Release

  test "local and GitHub authors are mutually exclusive" do
    local =
      Release.create_changeset(
        %Release{repository_id: 1, author_user_id: 2},
        valid_attrs()
      )

    assert local.valid?

    github =
      Release.import_changeset(
        %Release{repository_id: 1, author_github_identity_id: 3},
        Map.merge(valid_attrs(), %{"published_at" => ~U[2026-09-05 08:00:00Z]})
      )

    assert github.valid?

    neither = Release.create_changeset(%Release{repository_id: 1}, valid_attrs())
    refute neither.valid?
    assert "must identify exactly one author" in errors_on(neither).author_user_id

    both =
      Release.create_changeset(
        %Release{repository_id: 1, author_user_id: 2, author_github_identity_id: 3},
        valid_attrs()
      )

    refute both.valid?
    assert "must identify exactly one author" in errors_on(both).author_github_identity_id
  end

  test "draft and published timestamps stay coherent across legal transitions" do
    draft =
      Release.create_changeset(
        %Release{repository_id: 1, author_user_id: 2},
        Map.put(valid_attrs(), "draft", true)
      )

    assert draft.valid?
    assert Ecto.Changeset.get_field(draft, :published_at) == nil

    persisted = %{Ecto.Changeset.apply_changes(draft) | id: 9}
    published = Release.update_changeset(persisted, %{"draft" => false})
    assert published.valid?
    assert %DateTime{} = Ecto.Changeset.get_field(published, :published_at)

    published = Ecto.Changeset.apply_changes(published)
    unpublished = Release.update_changeset(published, %{"draft" => true})
    assert unpublished.valid?
    assert Ecto.Changeset.get_field(unpublished, :published_at) == nil
  end

  test "release metadata rejects NULs and malformed tag identity" do
    for {field, value} <- [
          {"tag_name", "bad\0tag"},
          {"name", "bad\0name"},
          {"body", "bad\0body"},
          {"target_commitish", "bad\0target"}
        ] do
      changeset =
        Release.create_changeset(
          %Release{repository_id: 1, author_user_id: 2},
          Map.put(valid_attrs(), field, value)
        )

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), String.to_atom(field))
    end

    for tag <- ["", " refs/tags/v1", "refs/tags/v1", "v1..0", "v1.lock"] do
      changeset =
        Release.create_changeset(
          %Release{repository_id: 1, author_user_id: 2},
          Map.put(valid_attrs(), "tag_name", tag)
        )

      refute changeset.valid?
      assert errors_on(changeset).tag_name != []
    end
  end

  defp valid_attrs do
    %{
      "tag_name" => "v1.0.0",
      "name" => "Version 1",
      "body" => "Release notes",
      "draft" => false,
      "prerelease" => false,
      "target_commitish" => "main"
    }
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
