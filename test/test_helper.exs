# capture_log: :logger output (e.g. from OtelLogger tests) is only shown for failing tests.
ExUnit.start(capture_log: true)

# The one shared setup: FakeHono listener, Finch, PubSub and the endpoint.
# Every test then gets its own isolated world (Frame.Test.Portal.start/1).
:ok = Frame.Test.Portal.start_shared()
