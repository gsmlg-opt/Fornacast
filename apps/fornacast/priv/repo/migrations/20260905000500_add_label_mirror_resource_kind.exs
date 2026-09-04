defmodule Fornacast.Repo.Migrations.AddLabelMirrorResourceKind do
  use Ecto.Migration

  @constraint :mirror_resource_states_resource_kind_check

  def up do
    unless turso?() do
      drop(constraint(:mirror_resource_states, @constraint))

      create(
        constraint(:mirror_resource_states, @constraint,
          check:
            "resource_kind in ('repository', 'label', 'issue', 'issue_comment', 'pull', 'release')"
        )
      )
    end
  end

  def down do
    unless turso?() do
      execute("delete from mirror_resource_states where resource_kind = 'label'")
      drop(constraint(:mirror_resource_states, @constraint))

      create(
        constraint(:mirror_resource_states, @constraint,
          check: "resource_kind in ('repository', 'issue', 'issue_comment', 'pull', 'release')"
        )
      )
    end
  end

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
