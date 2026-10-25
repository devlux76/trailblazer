root = hd(System.argv())

{us, {:ok, pid}} =
  :timer.tc(fn -> Trailblazer.Indexer.watch(root, embedding: :paused, filesystem: false) end)

IO.inspect(%{seconds: us / 1.0e6, status: Trailblazer.Indexer.status(root)}, label: "first watch")
GenServer.stop(pid)
