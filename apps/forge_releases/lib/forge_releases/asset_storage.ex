defmodule ForgeReleases.AssetStorage do
  @moduledoc false

  alias ForgeReleases.AssetStorage.{LocalCAS, Manager, Source, StagedRef}

  @type storage_key :: String.t()
  @type storage_error ::
          :not_found
          | :entity_too_large
          | :invalid_source
          | :integrity_mismatch
          | :ambiguous_commit
          | :busy_deleting
          | :unavailable
  @type metadata :: %{
          sha256_digest: storage_key(),
          storage_key: storage_key(),
          size: non_neg_integer()
        }
  @type capacity_metric :: %{total: non_neg_integer(), available: non_neg_integer()}
  @type filesystem_capacity :: %{bytes: capacity_metric(), inodes: capacity_metric()}
  @type capacity :: %{cas: filesystem_capacity(), staging: filesystem_capacity()}

  @callback stage_from_reader(String.t(), function(), state, keyword()) ::
              {:ok, StagedRef.t(), metadata(), state}
              | {:error, storage_error(), state}
            when state: term()
  @callback commit(StagedRef.t()) :: {:ok, metadata()} | {:error, storage_error()}
  @callback discard(StagedRef.t()) :: :ok | {:error, storage_error()}
  @callback stat(storage_key()) ::
              {:ok, %{storage_key: storage_key(), size: non_neg_integer()}}
              | {:error, storage_error()}
  @callback open(
              storage_key(),
              non_neg_integer(),
              :all | {non_neg_integer(), non_neg_integer()}
            ) :: {:ok, Source.t()} | {:error, storage_error()}
  @callback recover_stage(String.t(), storage_key(), non_neg_integer()) ::
              {:ok, StagedRef.t()} | {:error, storage_error()}
  @callback cleanup_staging(String.t()) :: :ok | {:error, storage_error()}
  @callback read(Source.t(), pos_integer()) ::
              {:ok, binary(), Source.t()} | :eof | {:error, storage_error()}
  @callback close(Source.t()) :: :ok
  @callback verify(storage_key()) :: :ok | {:error, storage_error()}
  @callback delete(storage_key()) :: :ok | {:error, storage_error()}
  @callback capacity() :: {:ok, capacity()} | {:error, storage_error()}

  @spec ready?() :: boolean()
  def ready?, do: Manager.ready?()

  @doc """
  Streams a caller-owned source into one staging directory.

  `:read_timeout` is capped at 30 seconds and passed to the callback as a
  cooperative deadline budget; the callback remains responsible for enforcing
  it and returning its latest classified state.
  """
  defdelegate stage_from_reader(staging_key, reader, state, options), to: LocalCAS
  defdelegate commit(staged_ref), to: LocalCAS
  defdelegate discard(staged_ref), to: LocalCAS
  defdelegate stat(storage_key), to: LocalCAS
  defdelegate open(storage_key, expected_size, range), to: LocalCAS

  @doc """
  Recovers the only direct regular survivor for an exclusively owned staging key.
  """
  defdelegate recover_stage(staging_key, expected_digest, expected_size), to: LocalCAS

  @doc """
  Durably cleans the direct survivor directory for an exclusively owned staging key.

  Callers must linearize this operation with recovery and staging for the same key.
  """
  defdelegate cleanup_staging(staging_key), to: LocalCAS
  defdelegate read(source, requested_bytes), to: LocalCAS
  defdelegate close(source), to: LocalCAS
  defdelegate verify(storage_key), to: LocalCAS
  defdelegate delete(storage_key), to: LocalCAS
  defdelegate capacity(), to: LocalCAS
end
