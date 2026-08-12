defmodule ForgeReleases.AssetStorage.Config do
  @moduledoc false

  alias ExStorageService.InstanceConfig

  @enforce_keys [
    :root,
    :data_root,
    :blob_root,
    :tmp_root,
    :ra_root,
    :metadata_root,
    :max_bytes,
    :gc_grace_seconds
  ]
  defstruct @enforce_keys ++ [:instance_config, :context]

  @type t :: %__MODULE__{}

  @spec load!() :: t()
  def load! do
    root = Fornacast.Config.release_asset_storage_root()
    instance_config = load_instance_config!()
    context = load_context!(instance_config)

    validate!(%__MODULE__{
      root: root,
      data_root: context.data_root,
      blob_root: context.blob_root,
      tmp_root: context.tmp_root,
      ra_root: context.ra_root,
      metadata_root: context.metadata_root,
      max_bytes: Fornacast.Config.release_asset_max_bytes(),
      gc_grace_seconds: Fornacast.Config.release_asset_gc_grace_seconds(),
      instance_config: instance_config,
      context: context
    })
  end

  @doc false
  @spec for_root!(String.t(), keyword()) :: t()
  def for_root!(root, options) when is_binary(root) and is_list(options) do
    root = Path.expand(root)

    validate!(%__MODULE__{
      root: root,
      data_root: root,
      blob_root: Path.join(root, "cas"),
      tmp_root: Path.join(root, "tmp"),
      ra_root: Path.join(root, "ra"),
      metadata_root: Path.join(root, "concord"),
      max_bytes: Keyword.fetch!(options, :max_bytes),
      gc_grace_seconds: Keyword.fetch!(options, :gc_grace_seconds)
    })
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = config) do
    validate_absolute_normalized!(:root, config.root)

    for {name, path} <- roots(config) do
      validate_absolute_normalized!(name, path)

      unless contained?(config.root, path) do
        raise ArgumentError, "#{name} must be contained by the release-asset root"
      end
    end

    unless is_integer(config.max_bytes) and config.max_bytes in 1..2_147_483_648 do
      raise ArgumentError, "release-asset maximum must be in 1..2147483648"
    end

    unless is_integer(config.gc_grace_seconds) and config.gc_grace_seconds >= 3_600 do
      raise ArgumentError, "release-asset GC grace must be at least 3600 seconds"
    end

    config
  end

  defp load_instance_config! do
    case InstanceConfig.from_application_env() do
      {:ok, instance_config} ->
        instance_config

      {:error, reason} ->
        raise ArgumentError,
              "invalid ex_storage_service instance configuration: #{reason}"
    end
  end

  defp load_context!(instance_config) do
    case ExStorageService.context(instance_config) do
      {:ok, context} ->
        context

      {:error, reason} ->
        raise ArgumentError, "invalid ex_storage_service context: #{reason}"
    end
  end

  defp roots(config) do
    [
      data_root: config.data_root,
      blob_root: config.blob_root,
      tmp_root: config.tmp_root,
      ra_root: config.ra_root,
      metadata_root: config.metadata_root
    ]
  end

  defp validate_absolute_normalized!(name, path) do
    unless is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path do
      raise ArgumentError, "#{name} must be an absolute normalized path"
    end
  end

  defp contained?(root, path) do
    relative = Path.relative_to(path, root)

    relative == "." or
      (relative != path and relative != ".." and not String.starts_with?(relative, "../"))
  end
end
