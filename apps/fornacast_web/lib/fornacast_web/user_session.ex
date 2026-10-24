defmodule FornacastWeb.UserSession do
  @moduledoc """
  Shares account configuration across independently owned login sessions.

  One user process holds appearance for each persisted user ID. Separate session
  processes hold only their owning user ID; their opaque IDs live in the signed
  cookie. Identity and authorization remain the responsibility of each request.
  Database loading and lifecycle operations run under a request-side user lock.
  """

  import Plug.Conn

  alias ForgeAccounts.User
  alias Phoenix.SessionProcess

  defmodule UserState do
    @moduledoc false
    use GenServer, restart: :temporary

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :arg),
        name: Keyword.fetch!(opts, :name)
      )
    end

    @impl true
    def init(configuration), do: {:ok, configuration}

    @impl true
    def handle_call({:appearance, user_id}, _from, %{user_id: user_id} = state) do
      {:reply, {:ok, state}, state}
    end

    def handle_call({:put_appearance, user_id, theme}, _from, %{user_id: user_id} = state) do
      {:reply, :ok, %{state | theme_preference: theme}}
    end

    def handle_call(_request, _from, state), do: {:reply, {:error, :owner_mismatch}, state}
  end

  defmodule SessionState do
    @moduledoc false
    use GenServer, restart: :temporary

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :arg),
        name: Keyword.fetch!(opts, :name)
      )
    end

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call({:owner, user_id}, _from, %{user_id: user_id} = state) do
      {:reply, {:ok, %{user_id: user_id}}, state}
    end

    def handle_call({:github_device, user_id, operation}, _from, %{user_id: user_id} = state) do
      {reply, attempt} =
        FornacastWeb.GitHubDeviceAttempt.transition(
          Map.get(state, :github_device),
          operation,
          System.monotonic_time(:millisecond)
        )

      {:reply, reply, Map.put(state, :github_device, attempt)}
    end

    def handle_call(
          {:organization_github_device, user_id, organization_id, operation},
          _from,
          %{user_id: user_id} = state
        )
        when is_integer(organization_id) and organization_id > 0 do
      attempts = Map.get(state, :organization_github_devices, %{})

      {reply, attempt} =
        FornacastWeb.GitHubDeviceAttempt.transition(
          Map.get(attempts, organization_id),
          operation,
          System.monotonic_time(:millisecond)
        )

      {:reply, reply,
       Map.put(state, :organization_github_devices, Map.put(attempts, organization_id, attempt))}
    end

    def handle_call(_request, _from, state), do: {:reply, {:error, :owner_mismatch}, state}

    @impl true
    def format_status(status) do
      status
      |> Map.put(:state, Map.take(status.state, [:user_id]))
      |> Map.update(:message, :redacted, fn _ -> :redacted end)
      |> Map.update(:reason, :redacted, fn _ -> :redacted end)
      |> Map.update(:log, [], fn _ -> [] end)
    end
  end

  @doc "Returns the stable package key for a persisted user or user ID."
  def user_process_id(%User{id: user_id}), do: user_process_id(user_id)
  def user_process_id(user_id) when is_integer(user_id), do: "fornacast_user_#{user_id}"

  @doc "Returns `{:ok, conn, hydrated_user}` or the session package's typed error."
  def hydrate(conn, %User{} = user) do
    with_user_lock(user.id, fn ->
      with {:ok, conn} <- ensure_session(conn, user.id),
           {:ok, configuration} <- user_configuration(user.id, nil) do
        {:ok, conn, %{user | theme_preference: configuration.theme_preference}}
      end
    end)
  end

  @doc "Rotates the login session and reuses existing shared user configuration."
  def log_in(conn, %User{} = user) do
    with {:ok, conn} <- log_out(conn) do
      with_user_lock(user.id, fn ->
        with {:ok, _configuration} <- user_configuration(user.id, user),
             {:ok, conn} <- start_session(conn, user.id) do
          {:ok, conn |> configure_session(renew: true) |> put_session(:user_id, user.id)}
        end
      end)
    end
  end

  @doc "Terminates only the owned login session, retaining shared user configuration."
  def log_out(conn) do
    session_id = get_session(conn, :session_id)
    user_id = get_session(conn, :user_id)

    result =
      if is_integer(user_id) and valid_session_id?(session_id) do
        with_user_lock(user_id, fn ->
          case SessionProcess.call(session_id, {:owner, user_id}) do
            {:ok, _owner} ->
              retire_process(session_id)

            {:error, {:session_not_found, _}} ->
              retire_process(session_id)

            {:error, :owner_mismatch} ->
              :ok

            {:error, {:call_failed, _}} = error ->
              if missing_process?(session_id), do: retire_process(session_id), else: error

            error ->
              error
          end
        end)
      else
        :ok
      end

    case result do
      :ok -> {:ok, delete_session(conn, :session_id)}
      error -> error
    end
  end

  @doc """
  Synchronizes a persisted appearance change into shared user configuration.

  Returns `{:ok, conn}` or `{:error, reason}`. Missing user state is initialized
  from the saved user without another database read. Other sessions reference
  this same user state, so their next request immediately sees the saved theme.
  """
  def put_appearance(conn, %User{} = user) do
    with_user_lock(user.id, fn -> put_shared_appearance(conn, user) end)
  end

  @doc """
  Serializes the account write and shared user-state update in the request process.

  Returns `{:ok, conn}`, the account changeset/domain error, or the session
  package's typed error. No database work runs inside either process type.
  """
  def save_appearance(conn, attrs) do
    user = conn.assigns.current_user

    with_user_lock(user.id, fn ->
      with {:ok, updated_user} <- ForgeAccounts.update_user_appearance(user, attrs) do
        put_shared_appearance(conn, updated_user)
      end
    end)
  end

  defp put_shared_appearance(conn, user) do
    result =
      with {:ok, conn} <- ensure_session(conn, user.id),
           {:ok, _configuration} <- user_configuration(user.id, user),
           :ok <-
             SessionProcess.call(
               user_process_id(user),
               {:put_appearance, user.id, user.theme_preference}
             ),
           :ok <- SessionProcess.touch(user_process_id(user)) do
        {:ok, conn}
      end

    case result do
      {:ok, _conn} ->
        result

      error ->
        retire_process(user_process_id(user))
        error
    end
  end

  defp ensure_session(conn, user_id) do
    session_id = get_session(conn, :session_id)

    if valid_session_id?(session_id) do
      case SessionProcess.call(session_id, {:owner, user_id}) do
        {:ok, _owner} ->
          case SessionProcess.touch(session_id) do
            :ok -> {:ok, conn}
            {:error, :not_found} -> replace_session(conn, user_id)
          end

        {:error, {:session_not_found, _}} ->
          replace_session(conn, user_id)

        {:error, :owner_mismatch} ->
          start_session(conn, user_id)

        {:error, {:call_failed, _}} = error ->
          if missing_process?(session_id), do: replace_session(conn, user_id), else: error

        error ->
          error
      end
    else
      start_session(conn, user_id)
    end
  end

  defp replace_session(conn, user_id) do
    with :ok <- retire_process(get_session(conn, :session_id)), do: start_session(conn, user_id)
  end

  defp start_session(conn, user_id) do
    session_id =
      "fornacast_session_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    case SessionProcess.start_session(session_id, module: SessionState, args: %{user_id: user_id}) do
      {:ok, _pid} -> {:ok, put_session(conn, :session_id, session_id)}
      error -> error
    end
  end

  defp user_configuration(user_id, seed) do
    id = user_process_id(user_id)

    case SessionProcess.call(id, {:appearance, user_id}) do
      {:ok, configuration} ->
        case SessionProcess.touch(id) do
          :ok -> {:ok, configuration}
          {:error, :not_found} -> initialize_user(user_id, seed)
        end

      {:error, {:session_not_found, _}} ->
        initialize_user(user_id, seed)

      {:error, {:call_failed, _}} = error ->
        if missing_process?(id), do: initialize_user(user_id, seed), else: error

      error ->
        error
    end
  end

  defp initialize_user(user_id, seed) do
    id = user_process_id(user_id)

    with :ok <- retire_process(id),
         {:ok, user} <- load_user(user_id, seed) do
      configuration = %{user_id: user_id, theme_preference: user.theme_preference}

      case SessionProcess.start_session(id, module: UserState, args: configuration) do
        {:ok, _pid} -> {:ok, configuration}
        error -> error
      end
    end
  end

  defp load_user(user_id, %User{id: user_id, state: :active} = seed), do: {:ok, seed}

  defp load_user(user_id, nil) do
    case ForgeAccounts.get_user(user_id) do
      %User{state: :active} = user -> {:ok, user}
      _ -> {:error, :user_not_found}
    end
  end

  @doc false
  def with_user_lock(user_id, function) do
    :global.trans({{__MODULE__, user_id}, self()}, function)
  end

  defp retire_process(id) do
    # Drain old cleanup callbacks and crashed-process tracking before reusing a user key.
    SessionProcess.Cleanup.cancel_session_cleanup(id)

    case SessionProcess.terminate(id) do
      :ok -> :ok
      {:error, {:session_not_found, _}} -> :ok
      error -> error
    end
  end

  defp missing_process?(id) do
    case SessionProcess.find_session(id) do
      {:error, :not_found} -> true
      {:ok, pid} -> not Process.alive?(pid)
    end
  end

  defp valid_session_id?(id) do
    Phoenix.SessionProcess.Config.valid_session_id?(id) and
      String.starts_with?(id, "fornacast_session_")
  end
end
