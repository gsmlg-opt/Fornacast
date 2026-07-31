defmodule FornacastAPI.GraphQL.Context do
  @moduledoc false
  @behaviour Plug

  alias FornacastAPI.Authentication

  def init(opts), do: opts

  def call(conn, _opts) do
    context =
      case conn.assigns[:api_auth] do
        %Authentication{actor: actor, api_key: api_key} ->
          %{actor: actor, api_key: api_key}

        _missing ->
          %{actor: nil, api_key: nil}
      end

    Absinthe.Plug.put_options(conn, context: context)
  end
end
