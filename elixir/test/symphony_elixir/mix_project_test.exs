defmodule SymphonyElixir.MixProjectTest do
  use ExUnit.Case, async: true

  test "coverage threshold stays high without requiring mechanical perfection" do
    threshold =
      SymphonyElixir.MixProject.project()
      |> Keyword.fetch!(:test_coverage)
      |> get_in([:summary, :threshold])

    assert threshold == 95
    assert threshold < 100
    assert threshold >= 95
  end
end
