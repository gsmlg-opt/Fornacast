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
end
