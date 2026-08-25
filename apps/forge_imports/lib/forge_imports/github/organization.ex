defmodule ForgeImports.GitHub.Organization do
  @moduledoc "A bounded GitHub organization representation."

  alias ForgeImports.GitHub.User

  @derive {Inspect, only: [:id, :login, :name, :description, :avatar_url, :html_url]}
  @enforce_keys [:id, :login]
  defstruct [:id, :login, :name, :description, :avatar_url, :html_url]

  @type t :: %__MODULE__{
          id: pos_integer(),
          login: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          avatar_url: String.t() | nil,
          html_url: String.t() | nil
        }

  @spec from_json(term()) :: {:ok, t()} | {:error, :invalid_response}
  def from_json(%{} = value) do
    with {:ok, id} <- User.id(value["id"]),
         {:ok, login} <- User.string(value["login"], 255, required?: true),
         {:ok, name} <- User.string(value["name"], 255),
         {:ok, description} <- User.string(value["description"], 1_000),
         {:ok, avatar_url} <- User.url(value["avatar_url"], ["avatars.githubusercontent.com"]),
         {:ok, html_url} <- User.url(value["html_url"], ["github.com"]) do
      {:ok,
       %__MODULE__{
         id: id,
         login: login,
         name: name,
         description: description,
         avatar_url: avatar_url,
         html_url: html_url
       }}
    else
      _error -> {:error, :invalid_response}
    end
  end

  def from_json(_value), do: {:error, :invalid_response}
end
