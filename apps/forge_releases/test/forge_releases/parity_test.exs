defmodule ForgeReleases.ParityTest do
  use ExUnit.Case, async: false
  import ForgeReleases.Fixtures
  alias ForgeReleases.Release
  alias Fornacast.Repo

  setup do
    reset_database!()
    owner = user_fixture("parity#{System.unique_integer([:positive])}")
    repository = repository_fixture(owner, %{visibility: :public})
    Enum.each(["v1.0.0", "v2.0.0", "v3.0.0"], &put_tag(repository, &1))
    %{owner: owner, repository: repository}
  end

  test "explicit latest selection can promote an older release and exclude newer ones", c do
    first = create(c, "v1.0.0")
    second = create(c, "v2.0.0")
    _third = create(c, "v3.0.0", %{"make_latest" => "false"})
    assert {:ok, %{id: id}} = ForgeReleases.latest(nil, c.owner.username, c.repository.slug)
    assert id == second.id

    assert {:ok, _} =
             ForgeReleases.update(
               c.owner,
               c.owner.username,
               c.repository.slug,
               first.id,
               %{"make_latest" => "true"},
               %{}
             )

    assert {:ok, %{id: id}} = ForgeReleases.latest(nil, c.owner.username, c.repository.slug)
    assert id == first.id
  end

  test "legacy selection uses the highest semantic version and skips drafts/prereleases", c do
    second = create(c, "v2.0.0", %{"make_latest" => "legacy"})
    _first = create(c, "v1.0.0", %{"make_latest" => "legacy"})
    _third = create(c, "v3.0.0", %{"draft" => true})
    assert {:ok, %{id: id}} = ForgeReleases.latest(nil, c.owner.username, c.repository.slug)
    assert id == second.id
  end

  test "generate_release_notes creates real notes and preserves a supplied introduction", c do
    release = create(c, "v1.0.0", %{"generate_release_notes" => true, "body" => "Introduction"})
    assert String.starts_with?(release.body, "Introduction\n\n## Changes")
    assert release.body =~ "release v1.0.0"
  end

  test "immutable release metadata and deletion fail closed", c do
    release = create(c, "v1.0.0")
    Repo.update!(Ecto.Changeset.change(release, immutable: true))

    assert {:error, {:validation, [%{field: "immutable"}]}} =
             ForgeReleases.update(
               c.owner,
               c.owner.username,
               c.repository.slug,
               release.id,
               %{"body" => "edited"},
               %{}
             )

    assert {:error, {:validation, [%{field: "immutable"}]}} =
             ForgeReleases.delete(c.owner, c.owner.username, c.repository.slug, release.id, %{})

    assert Repo.get!(Release, release.id).deleted_at == nil
  end

  test "historical body projections are cleared when local body changes", c do
    release = create(c, "v1.0.0")

    Repo.update!(
      Ecto.Changeset.change(release,
        source_metadata: %{"body_html" => "old", "body_text" => "old", "mentions_count" => 2}
      )
    )

    assert {:ok, updated} =
             ForgeReleases.update(
               c.owner,
               c.owner.username,
               c.repository.slug,
               release.id,
               %{"body" => "new"},
               %{}
             )

    assert updated.source_metadata == %{}
  end

  test "source reaction aggregates require the complete validated GitHub shape" do
    counters = Map.new(~w(total_count +1 -1 laugh hooray confused heart rocket eyes), &{&1, 0})

    metadata = %{
      "reactions" =>
        Map.put(counters, "url", "https://api.github.com/repos/acme/demo/releases/1/reactions")
    }

    assert Release.valid_source_metadata?(metadata)
    refute Release.valid_source_metadata?(%{"reactions" => %{"total_count" => 4}})

    refute Release.valid_source_metadata?(
             put_in(metadata, ["reactions", "url"], "http://127.0.0.1/reactions")
           )

    refute Release.valid_source_metadata?(%{"mentions_count" => -1})
  end

  defp create(c, tag, extra \\ %{}) do
    {:ok, release} =
      ForgeReleases.create(
        c.owner,
        c.owner.username,
        c.repository.slug,
        Map.merge(%{"tag_name" => tag}, extra),
        %{}
      )

    release
  end
end
