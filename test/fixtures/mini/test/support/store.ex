defmodule Mini.Store do
  # A second Mini.Store, in the test support: the same qualified name as the one
  # in lib, so a name can resolve to more than one definition.
  def put(hikes, _opts), do: {:error, :duplicate_module, hikes}
end
