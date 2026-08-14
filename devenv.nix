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

  processes.fornacast = {
    exec = "mix fornacast.run";
    ready = {
      http.get = {
        host = "127.0.0.1";
        port = 4891;
        path = "/health";
      };
      period = 1;
      probe_timeout = 2;
      timeout = 300;
    };
  };

  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_17;
    port = 55432;
    listen_addresses = "";
    initialDatabases = [
      {name = "fornacast_test";}
    ];
  };
}
