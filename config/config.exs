# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :mxc,
  ecto_repos: [Mxc.Repo],
  generators: [timestamp_type: :utc_datetime],
  # Mode: :coordinator, :agent, or :standalone (default for dev)
  mode: :standalone,
  # Whether to enable the web UI (coordinator mode only)
  ui_enabled: true,
  # Cluster strategy: :postgres, :gossip, :dns, :epmd
  cluster_strategy: :gossip,
  # Scheduler strategy: :spread (distribute load) or :pack (bin-pack)
  scheduler_strategy: :spread

# Configure the endpoint
config :mxc, MxcWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MxcWeb.ErrorHTML, json: MxcWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Mxc.PubSub,
  live_view: [signing_salt: "3Ft+OhSr"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :mxc, Mxc.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  mxc: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  mxc: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
