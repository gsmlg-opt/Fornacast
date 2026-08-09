defmodule ForgePulls.ChangedFilePage do
  @enforce_keys [:entries, :total, :page, :per_page, :truncated]
  defstruct [:entries, :total, :page, :per_page, :truncated]

  @type t :: %__MODULE__{
          entries: [struct()],
          total: non_neg_integer(),
          page: pos_integer(),
          per_page: pos_integer(),
          truncated: boolean()
        }
end
