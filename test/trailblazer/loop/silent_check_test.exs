defmodule Trailblazer.Loop.SilentCheckTest do
  use ExUnit.Case, async: true
  alias Trailblazer.Loop.{Check, SilentCheck}

  setup do
    dir = Path.join(System.tmp_dir!(), "silent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "big.ts"), String.duplicate("x\n", 766))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a silent failing test step is named with its expanded values", %{dir: dir} do
    cmd = "test -f big.ts && test $(wc -l < big.ts) -le 640 && echo ok"
    result = Check.run(dir, cmd)
    assert result.status == :fail
    assert result.output_tail =~ "This step failed: `test $(wc -l < big.ts) -le 640`"
    assert result.output_tail =~ "+ test 766 -le 640"
  end

  test "failures with output and passes are left alone", %{dir: dir} do
    loud = %{status: :fail, output_tail: "1 failed", exit: 1, ms: 1}
    assert SilentCheck.annotate(loud, dir, "test 1 = 2") == loud
    pass = %{status: :pass, output_tail: "", exit: 0, ms: 1}
    assert SilentCheck.annotate(pass, dir, "test 1 = 2") == pass
    silent = %{status: :fail, output_tail: "", exit: 1, ms: 1}
    assert SilentCheck.annotate(silent, dir, "false").output_tail =~ "printed nothing"
  end
end
