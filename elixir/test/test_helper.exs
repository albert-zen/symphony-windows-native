ExUnit.start()
ExUnit.configure(exclude: [windows_native: true])
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
