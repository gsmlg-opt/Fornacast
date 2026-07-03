defmodule Mix.Tasks.Fornacast.Admin.Create do
  use Mix.Task

  @shortdoc "Creates the first Fornacast admin user"

  @moduledoc """
  Creates the first Fornacast admin user.

      mix fornacast.admin.create \\
        --username alice \\
        --email alice@example.com \\
        --password "correct horse battery staple"

  The task refuses to create another admin once one already exists.
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    attrs = parse_args!(args)

    case ForgeAccounts.create_first_admin(attrs) do
      {:ok, user} ->
        Mix.shell().info("Created admin user #{user.username}")

      {:error, :admin_exists} ->
        Mix.raise("an admin user already exists")

      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.raise("could not create admin: #{inspect(changeset.errors)}")
    end
  end

  defp parse_args!(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [username: :string, email: :string, password: :string]
      )

    if rest != [] or invalid != [] do
      Mix.raise(
        "usage: mix fornacast.admin.create --username USER --email EMAIL --password PASSWORD"
      )
    end

    %{
      username: required!(opts, :username),
      email: required!(opts, :email),
      password: required!(opts, :password)
    }
  end

  defp required!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("missing required --#{key}")
    end
  end
end
