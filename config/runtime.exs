import Config

# The release serves HTTP; dev/test start nothing (tests build their own).
if config_env() == :prod do
  config :frame, serve: true
end
