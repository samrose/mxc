defmodule Mxc.Application do
  @moduledoc """
  The Mxc OTP Application.

  Starts different services based on the configured mode:
  - :coordinator - Runs the coordinator with web UI and API
  - :agent - Runs the agent that executes workloads
  - :standalone - Runs both coordinator and agent (for development)
  """

  use Application

  @impl true
  def start(_type, _args) do
    mode = Application.get_env(:mxc, :mode, :standalone)

    children = base_children() ++ mode_children(mode)

    opts = [strategy: :one_for_one, name: Mxc.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp base_children do
    [
      MxcWeb.Telemetry,
      {Phoenix.PubSub, name: Mxc.PubSub}
    ]
  end

  defp mode_children(:coordinator) do
    ui_enabled = Application.get_env(:mxc, :ui_enabled, true)

    [
      Mxc.Repo,
      Mxc.Coordinator.Supervisor
    ] ++ web_children(ui_enabled)
  end

  defp mode_children(:agent) do
    # Agent mode - no database, no web UI
    [
      Mxc.Agent.Supervisor
    ]
  end

  defp mode_children(:standalone) do
    # Development mode - run everything
    ui_enabled = Application.get_env(:mxc, :ui_enabled, true)

    base = [
      Mxc.Repo,
      Mxc.Coordinator.Supervisor
    ]

    # Don't start Agent in test (Executor needs erlexec, Health auto-registers)
    agent =
      if Application.get_env(:mxc, :start_agent, true) do
        [Mxc.Agent.Supervisor]
      else
        []
      end

    base ++ agent ++ web_children(ui_enabled)
  end

  defp web_children(true) do
    [
      {DNSCluster, query: Application.get_env(:mxc, :dns_cluster_query) || :ignore},
      MxcWeb.Endpoint
    ]
  end

  defp web_children(false) do
    # API-only mode - still need endpoint for API
    [
      {DNSCluster, query: Application.get_env(:mxc, :dns_cluster_query) || :ignore},
      MxcWeb.Endpoint
    ]
  end

  @impl true
  def config_change(changed, _new, removed) do
    MxcWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
