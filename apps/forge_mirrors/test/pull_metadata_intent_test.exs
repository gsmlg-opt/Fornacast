defmodule ForgeMirrors.PullMetadataIntentTest do
  use ExUnit.Case, async: true

  alias ForgeMirrors.PullMetadataIntent

  test "hashes complete evidence larger than the operation marker budget" do
    payload = %{"expected" => String.duplicate("a", 70_000)}
    changeset = PullMetadataIntent.create_changeset(%PullMetadataIntent{}, attrs(payload))
    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :payload) == payload

    assert Ecto.Changeset.get_field(changeset, :payload_fingerprint) ==
             elem(ForgeMirrors.resource_fingerprint(payload), 1)
  end

  test "rejects invalid bounds and ignores a caller supplied fingerprint" do
    refute PullMetadataIntent.create_changeset(
             %PullMetadataIntent{},
             attrs(%{"body" => String.duplicate("a", 2_000_001)})
           ).valid?

    refute PullMetadataIntent.create_changeset(%PullMetadataIntent{}, %{attrs(%{}) | sequence: 0}).valid?

    changeset =
      PullMetadataIntent.create_changeset(
        %PullMetadataIntent{},
        Map.put(attrs(%{}), :payload_fingerprint, String.duplicate("0", 64))
      )

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :payload_fingerprint) != String.duplicate("0", 64)
  end

  test "loaded evidence cannot be replaced" do
    saved = %PullMetadataIntent{operation_id: 1, sequence: 1, payload: %{"old" => true}}
    saved = Ecto.put_meta(saved, state: :loaded)
    refute PullMetadataIntent.create_changeset(saved, attrs(%{"new" => true})).valid?
  end

  defp attrs(payload),
    do: %{
      operation_id: 1,
      repository_mirror_id: 2,
      pull_id: 3,
      issue_id: 4,
      local_version: 5,
      sequence: 1,
      payload: payload
    }
end
