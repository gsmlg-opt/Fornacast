defmodule FornacastAPI.DevenvProcessContractTest do
  use ExUnit.Case, async: true

  @devenv Path.expand("../../../devenv.nix", __DIR__)

  test "devenv manages Fornacast and waits for the API health endpoint" do
    config = File.read!(@devenv)

    assert config =~ """
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
           """
  end

  test "devenv provisions the PostgreSQL development and test databases" do
    source = File.read!(@devenv)

    assert source =~ ~s(package = pkgs-stable.postgresql_17)
    assert source =~ ~s(port = 55432)
    assert source =~ ~s(listen_addresses = "")
    assert source =~ ~s({name = "fornacast_dev";})
    assert source =~ ~s({name = "fornacast_test";})
  end
end
