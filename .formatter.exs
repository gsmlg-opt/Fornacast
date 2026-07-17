[
  import_deps: [:ecto, :phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter, DuskmoonBundler.Formatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,apps,test}/**/*.{ex,exs,heex}",
    "apps/fornacast_web/assets/**/*.{js,ts,jsx,tsx}"
  ]
]
