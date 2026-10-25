defmodule Mini.App do
  alias Mini.Store

  def run(hikes), do: Store.put(hikes, [])
end
