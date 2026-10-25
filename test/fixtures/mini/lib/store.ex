defmodule Mini.Store do
  def put(hikes, opts) do
    # Implements docs/design.md §2. The old docs/design.md §9 is gone.
    _ = opts
    {:ok, hikes}
  end
end
