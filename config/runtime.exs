import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# ============================================================================
# Mxc Configuration
# ============================================================================

# Mode configuration - determines which services to start
# - coordinator: Runs coordinator with web UI/API
# - agent: Runs agent that executes workloads
# - standalone: Runs both (for development)
if mode = System.get_env("MXC_MODE") do
  config :mxc, mode: String.to_atom(mode)
end

# UI toggle (coordinator mode only)
if ui_enabled = System.get_env("MXC_UI_ENABLED") do
  config :mxc, ui_enabled: ui_enabled in ~w(true 1 yes)
end

# Cluster strategy
if cluster_strategy = System.get_env("MXC_CLUSTER_STRATEGY") do
  config :mxc, cluster_strategy: String.to_atom(cluster_strategy)
end

# Scheduler strategy
if scheduler_strategy = System.get_env("MXC_SCHEDULER_STRATEGY") do
  config :mxc, scheduler_strategy: String.to_atom(scheduler_strategy)
end

# Database configuration for postgres clustering
if db_host = System.get_env("DATABASE_HOST") do
  config :mxc,
    database_host: db_host,
    database_port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
    database_user: System.get_env("DATABASE_USER", "mxc"),
    database_password: System.get_env("DATABASE_PASSWORD", ""),
    database_name: System.get_env("DATABASE_NAME", "mxc")
end

# Agent-specific configuration
if cpu_cores = System.get_env("MXC_AGENT_CPU") do
  config :mxc, cpu_cores: String.to_integer(cpu_cores)
end

if memory_mb = System.get_env("MXC_AGENT_MEMORY") do
  config :mxc, memory_mb: String.to_integer(memory_mb)
end

if hypervisor = System.get_env("MXC_HYPERVISOR") do
  config :mxc, hypervisor: String.to_atom(hypervisor)
end

# Gossip clustering configuration
if gossip_port = System.get_env("MXC_GOSSIP_PORT") do
  config :mxc, gossip_port: String.to_integer(gossip_port)
end

if gossip_secret = System.get_env("MXC_GOSSIP_SECRET") do
  config :mxc, gossip_secret: gossip_secret
end

# DNS clustering configuration
if dns_query = System.get_env("MXC_DNS_QUERY") do
  config :mxc, dns_query: dns_query
end

# EPMD clustering configuration
if cluster_hosts = System.get_env("MXC_CLUSTER_HOSTS") do
  hosts =
    cluster_hosts
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)

  config :mxc, cluster_hosts: hosts
end

# API authentication token
if api_token = System.get_env("MXC_API_TOKEN") do
  config :mxc, :api_token, api_token
end

# ============================================================================
# Phoenix/Web Configuration
# ============================================================================

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/mxc start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :mxc, MxcWeb.Endpoint, server: true
end

config :mxc, MxcWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  mode = System.get_env("MXC_MODE", "standalone")

  # Database only required for coordinator/standalone modes (not agent)
  if mode in ["coordinator", "standalone"] do
    database_url =
      System.get_env("DATABASE_URL") ||
        raise """
        environment variable DATABASE_URL is missing.
        For example: ecto://USER:PASS@HOST/DATABASE
        """

    maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

    config :mxc, Mxc.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      socket_options: maybe_ipv6

    secret_key_base =
      System.get_env("SECRET_KEY_BASE") ||
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

    host = System.get_env("PHX_HOST") || "example.com"

    config :mxc, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

    config :mxc, MxcWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
      secret_key_base: secret_key_base
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :mxc, MxcWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :mxc, MxcWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :mxc, Mxc.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
