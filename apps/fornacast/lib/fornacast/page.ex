defmodule Fornacast.Page do
  @enforce_keys [:entries, :total, :page, :per_page]
  defstruct [:entries, :total, :page, :per_page]

  @type t(value) :: %__MODULE__{
          entries: [value],
          total: non_neg_integer(),
          page: pos_integer(),
          per_page: 1..100
        }

  def total_pages(%__MODULE__{total: 0}), do: 1

  def total_pages(%__MODULE__{total: total, per_page: per_page}),
    do: div(total + per_page - 1, per_page)
end
