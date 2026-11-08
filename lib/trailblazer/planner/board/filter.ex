defmodule Trailblazer.Planner.Board.Filter do
  @moduledoc "The bounding filter the default planner runner pipes each board and show reply through."

  # Bounds a reply under the check tail. A board reply is stripped to the
  # eligibility facts per card (ref, actor, priority); a show reply keeps its
  # text bounded. Invalid JSON or an error object leaves through a non-zero
  # exit, which the check reports as a fail.
  @filter ~S'''
  import sys, json
  sys.stdout.reconfigure(encoding="utf-8")
  try:
      d = json.load(sys.stdin)
  except Exception:
      sys.exit(1)
  if not isinstance(d, dict) or "error" in d:
      print(json.dumps(d)[:2000] if isinstance(d, dict) else "")
      sys.exit(1)

  def cut(x, n):
      return x[:n] if isinstance(x, str) else x

  # The routing markers (Route) are lines anywhere in the body, and a plan
  # usually starts past the excerpt: a marker line not whole in the excerpt
  # follows it, bounded. A cut-off last line is dropped, so a half marker
  # line is never read first.
  MARKERS = ("Files:", "Acceptance:", "Implementation plan:")

  def body(b):
      if not isinstance(b, str):
          return b
      b = b.replace("\r\n", "\n")
      lines = b.split("\n")
      head = b[:400]
      if len(b) > 400:
          if "\n" in head:
              head = head[:head.rfind("\n")]
          elif head.startswith(MARKERS):
              head = ""
      whole = set(head.split("\n"))
      for m in MARKERS:
          line = next((l for l in lines if l.startswith(m)), None)
          if line is None or line in whole:
              continue
          if len(line) > 200:
              if m == "Files:":
                  # a path is never cut: no separator in reach drops the line
                  cut_at = max(line.rfind(",", 0, 200), line.rfind(" ", 0, 200))
                  if cut_at <= len(m):
                      continue
                  line = line[:cut_at]
              else:
                  line = line[:200]
          head += "\n" + line
      return head

  if isinstance(d.get("cards"), list):
      rows = []
      for c in d["cards"]:
          if isinstance(c, dict) and isinstance(c.get("ref"), str):
              rows.append([c["ref"], c.get("actor"), c.get("priority")])
      print(json.dumps({"cards": rows}, ensure_ascii=False))
  else:
      if "title" in d:
          d["title"] = cut(d["title"], 200)
      if "body" in d:
          d["body"] = body(d["body"])
      if isinstance(d.get("recent"), list):
          d["recent"] = [cut(c, 150) for c in d["recent"][:3]]
      if isinstance(d.get("claim"), dict) and isinstance(d["claim"].get("notes"), list):
          d["claim"]["notes"] = [{"n": n.get("n"), "action": cut(n.get("action"), 20),
                                  "text": cut(n.get("text"), 150)}
                                 for n in d["claim"]["notes"][-3:]]
      print(json.dumps(d, ensure_ascii=False))
  '''

  @doc "The filter's Python source, passed to `python3 -c`."
  def script, do: @filter
end
