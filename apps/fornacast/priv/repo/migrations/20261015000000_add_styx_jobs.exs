defmodule Fornacast.Repo.Migrations.AddStyxJobs do
  use Ecto.Migration

  def up, do: Styx.Migration.up()
  def down, do: Styx.Migration.down()
end
