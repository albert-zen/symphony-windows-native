%{
  configs: [
    %{
      name: "default",
      checks: %{
        disabled: [
          {Credo.Check.Consistency.LineEndings, []}
        ]
      }
    }
  ]
}
