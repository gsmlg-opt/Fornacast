{
  pkgs,
  lib,
  inputs,
  ...
}: let
  pkgs-stable = import inputs.nixpkgs-stable {system = pkgs.stdenv.system;};
in {
  env.ELIXIR_ERL_OPTIONS = "+B";

  packages = with pkgs-stable;
    [
      git
      pkg-config
      openssl
      cargo
      rustc
    ]
    ++ lib.optionals stdenv.isLinux [
      inotify-tools
    ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam29Packages.elixir_1_20;

  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_17;
    initialDatabases = [
      {name = "fornacast_test";}
    ];
  };
}
