# capture_log: :logger output (e.g. from OtelLogger tests) is only shown for failing tests.
ExUnit.start(capture_log: true)

# Ecto.Migrator loads the same migration file once per test database.
Code.put_compiler_option(:ignore_module_conflict, true)
