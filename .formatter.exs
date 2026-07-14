[
  import_deps: [:ecto, :phoenix],
  plugins: [DuskmoonBundler.Formatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,apps,test}/**/*.{ex,exs}",
    "apps/fornacast_web/assets/**/*.{js,ts,jsx,tsx}"
  ]
]
