[
  import_deps: [:ecto, :phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter, DuskmoonBundler.Formatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,test}/**/*.{ex,exs,heex}",
    "apps/*/{mix,.formatter}.exs",
    "apps/*/{config,lib,test}/**/*.{ex,exs,heex}",
    "apps/fornacast_web/assets/**/*.{js,ts,jsx,tsx}"
  ]
]
