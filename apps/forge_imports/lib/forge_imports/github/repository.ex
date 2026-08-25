defmodule ForgeImports.GitHub.Repository do
  @moduledoc "A bounded GitHub repository representation used by discovery."

  alias ForgeImports.GitHub.User

  @derive {Inspect,
           only: [
             :id,
             :name,
             :full_name,
             :owner_login,
             :description,
             :visibility,
             :default_branch,
             :has_issues,
             :allow_merge_commit,
             :fork,
             :archived,
             :html_url,
             :updated_at,
             :pushed_at
           ]}
  @enforce_keys [
    :id,
    :name,
    :full_name,
    :owner_login,
    :visibility,
    :default_branch,
    :has_issues,
    :allow_merge_commit,
    :fork,
    :archived
  ]
  defstruct [
    :id,
    :name,
    :full_name,
    :owner_login,
    :description,
    :visibility,
    :default_branch,
    :has_issues,
    :allow_merge_commit,
    :fork,
    :archived,
    :html_url,
    :updated_at,
    :pushed_at
  ]

  @type visibility :: :public | :private | :internal
  @type t :: %__MODULE__{
          id: pos_integer(),
          name: String.t(),
          full_name: String.t(),
          owner_login: String.t(),
          description: String.t() | nil,
          visibility: visibility(),
          default_branch: String.t(),
          has_issues: boolean(),
          allow_merge_commit: boolean() | nil,
          fork: boolean(),
          archived: boolean(),
          html_url: String.t() | nil,
          updated_at: DateTime.t() | nil,
          pushed_at: DateTime.t() | nil
        }

  @spec from_json(term()) :: {:ok, t()} | {:error, :invalid_response}
  def from_json(%{"owner" => %{} = owner} = value) do
    with {:ok, id} <- User.id(value["id"]),
         {:ok, name} <- User.string(value["name"], 100, required?: true),
         {:ok, full_name} <- User.string(value["full_name"], 255, required?: true),
         {:ok, owner_login} <- User.string(owner["login"], 255, required?: true),
         {:ok, description} <- User.string(value["description"], 1_000),
         {:ok, visibility} <- visibility(value["visibility"]),
         {:ok, default_branch} <- User.string(value["default_branch"], 255, required?: true),
         {:ok, has_issues} <- User.boolean(value["has_issues"]),
         {:ok, allow_merge_commit} <- optional_boolean(value, "allow_merge_commit"),
         {:ok, fork} <- User.boolean(value["fork"]),
         {:ok, archived} <- User.boolean(value["archived"]),
         {:ok, html_url} <- User.url(value["html_url"], ["github.com"]),
         {:ok, updated_at} <- User.datetime(value["updated_at"]),
         {:ok, pushed_at} <- User.datetime(value["pushed_at"]) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         full_name: full_name,
         owner_login: owner_login,
         description: description,
         visibility: visibility,
         default_branch: default_branch,
         has_issues: has_issues,
         allow_merge_commit: allow_merge_commit,
         fork: fork,
         archived: archived,
         html_url: html_url,
         updated_at: updated_at,
         pushed_at: pushed_at
       }}
    else
      _error -> {:error, :invalid_response}
    end
  end

  def from_json(_value), do: {:error, :invalid_response}

  defp visibility("public"), do: {:ok, :public}
  defp visibility("private"), do: {:ok, :private}
  defp visibility("internal"), do: {:ok, :internal}
  defp visibility(_value), do: :error

  defp optional_boolean(value, key) do
    case Map.fetch(value, key) do
      :error -> {:ok, nil}
      {:ok, boolean} -> User.boolean(boolean)
    end
  end
end
