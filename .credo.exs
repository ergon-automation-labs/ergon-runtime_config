%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: [
        {Credo.Check.Design.AliasUsage, false},
        {Credo.Check.Readability.AliasOrder, false},
        {Credo.Check.Refactor.ModuleDependencies, max_deps: 20}
      ]
    }
  ]
}
