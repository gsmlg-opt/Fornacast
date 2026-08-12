Code.require_file("support/test_dirty_io_native.exs", __DIR__)
GitTransport.TestDirtyIoNative.load!()

ExUnit.start()
