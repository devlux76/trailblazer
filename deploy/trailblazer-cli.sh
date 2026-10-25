#!/bin/sh
# Trailblazer CLI wrapper, installed as ~/.local/bin/trailblazer:
#   mix escript.build
#   install -D _build/escript/trailblazer ~/.local/share/trailblazer/bin/trailblazer.escript
#   install deploy/trailblazer-cli.sh ~/.local/bin/trailblazer
# The escript runs on mise's pinned Erlang, with UTF-8 file names, whatever PATH
# and locale the caller has.
ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}" PATH="$HOME/.local/share/mise/shims:$PATH" exec "$HOME/.local/share/trailblazer/bin/trailblazer.escript" "$@"
