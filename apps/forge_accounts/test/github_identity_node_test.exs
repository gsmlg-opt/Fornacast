defmodule ForgeAccounts.GitHubIdentityNodeTest do
  use ExUnit.Case, async: false
  alias ForgeAccounts.GitHubIdentity
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    %{id: System.unique_integer([:positive, :monotonic]), now: DateTime.utc_now(:second)}
  end

  test "authenticated profile preserves an opaque node without inferring it", c do
    node = "U_opaque_#{c.id}"
    assert {:ok, identity} = observe(c, %{node_id: node})
    assert Map.get(identity, :github_node_id) == node
    assert {:ok, missing} = observe(%{c | id: c.id + 1_000_000}, %{})
    assert Map.get(missing, :github_node_id) == nil
  end

  test "older authenticated observation may seed a node without regressing profile", c do
    assert {:ok, first} = observe(c, %{login: "new-name"})

    assert {:ok, seeded} =
             observe(%{c | now: DateTime.add(c.now, -60)}, %{
               login: "old-name",
               node_id: "U_#{c.id}"
             })

    assert seeded.id == first.id
    assert seeded.login == "new-name"
    assert Map.get(seeded, :github_node_id) == "U_#{c.id}"
  end

  test "omitted or null node does not clear established association", c do
    assert {:ok, first} = observe(c, %{node_id: "U_#{c.id}"})

    for attrs <- [%{}, %{node_id: nil}] do
      assert {:ok, refreshed} = observe(c, attrs)
      assert Map.get(refreshed, :github_node_id) == "U_#{c.id}"
      assert refreshed.id == first.id
    end
  end

  test "conflicting node rejects the whole observation", c do
    assert {:ok, first} = observe(c, %{node_id: "U_#{c.id}", login: "original"})
    assert {:error, _} = observe(c, %{node_id: "different", login: "must-not-update"})
    assert Repo.get!(GitHubIdentity, first.id).login == "original"
    assert Map.get(Repo.get!(GitHubIdentity, first.id), :github_node_id) == "U_#{c.id}"
  end

  test "node belongs to only one numeric identity and uniqueness errors preserve outer transaction",
       c do
    assert {:ok, _} = observe(c, %{node_id: "U_#{c.id}"})

    assert {:ok, :usable} =
             Repo.transaction(fn ->
               assert {:error, rejected} =
                        observe(%{c | id: c.id + 1_000_000}, %{node_id: "U_#{c.id}"})

               assert rejected.errors[:github_node_id]
               assert %{rows: [[1]]} = Repo.query!("SELECT 1")
               :usable
             end)
  end

  test "node is bounded in bytes and whitespace is rejected", c do
    assert {:ok, maximum} = observe(c, %{node_id: String.duplicate("n", 512)})
    assert byte_size(Map.fetch!(maximum, :github_node_id)) == 512

    for node <- ["", " padded", "padded ", "bad\0node", String.duplicate("😀", 129)] do
      assert {:error, _} = observe(%{c | id: c.id + 1_000_000}, %{node_id: node})
    end
  end

  test "deleted identity node remains nil at the database boundary", _c do
    deleted = ForgeAccounts.github_deleted_identity()
    assert Map.get(deleted, :github_node_id) == nil

    changeset =
      deleted
      |> Ecto.Changeset.change(github_node_id: "U_deleted")
      |> Ecto.Changeset.check_constraint(:github_node_id, name: :github_identities_node_check)

    assert {:error, rejected} = Repo.update(changeset, mode: :savepoint)
    assert rejected.errors[:github_node_id]
  end

  test "loaded identity changeset cannot replace or clear its node", c do
    assert {:ok, first} = observe(c, %{node_id: "U_#{c.id}"})
    refute GitHubIdentity.observed_changeset(first, %{github_node_id: "different"}).valid?
    changeset = GitHubIdentity.observed_changeset(first, %{github_node_id: nil})
    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :github_node_id) == "U_#{c.id}"
  end

  test "retained node aliases receive existing credential safety checks", _c do
    for key <- [:node_id, "node_id", :github_node_id, "github_node_id"] do
      assert {:error, :invalid_response} =
               ForgeAccounts.GitHubProfileSafety.validate(%{key => "ghp_secret-token"})
    end
  end

  defp observe(c, attrs),
    do:
      ForgeAccounts.observe_github_identity(
        Map.merge(%{id: c.id, login: "node-user"}, attrs),
        c.now
      )
end
