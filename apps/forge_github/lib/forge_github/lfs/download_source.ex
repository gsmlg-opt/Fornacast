defmodule ForgeGitHub.LFS.DownloadSource do
  @moduledoc "Opaque state for a bounded, pull-driven GitHub LFS download."

  @enforce_keys [:api, :connection, :reference, :deadline, :expected_size, :expected_oid, :hash]
  defstruct @enforce_keys ++
              [
                :status,
                headers: [],
                header_size: 0,
                pending: "",
                received: 0,
                error_body: [],
                error_size: 0,
                done: false,
                completed: false,
                error: nil
              ]

  @opaque t :: %__MODULE__{
            api: module(),
            connection: term(),
            reference: reference(),
            deadline: integer(),
            expected_size: non_neg_integer(),
            expected_oid: String.t(),
            hash: term(),
            status: integer() | nil,
            headers: [[{String.t(), String.t()}]],
            header_size: non_neg_integer(),
            pending: binary(),
            received: non_neg_integer(),
            error_body: [binary()],
            error_size: non_neg_integer(),
            done: boolean(),
            completed: boolean(),
            error: atom() | nil
          }
end

defimpl Inspect, for: ForgeGitHub.LFS.DownloadSource do
  def inspect(_source, _options), do: "#ForgeGitHub.LFS.DownloadSource<redacted>"
end
