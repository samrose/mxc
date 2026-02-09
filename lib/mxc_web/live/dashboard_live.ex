defmodule MxcWeb.DashboardLive do
  use MxcWeb, :live_view

  alias Mxc.Coordinator

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
      Phoenix.PubSub.subscribe(Mxc.PubSub, "fact_changes")
    end

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:fact_change, _, _, _}, socket) do
    {:noreply, load_data(socket)}
  end

  defp load_data(socket) do
    status = Coordinator.cluster_status()
    nodes = Coordinator.list_nodes()
    workloads = Coordinator.list_workloads()

    socket
    |> assign(:status, status)
    |> assign(:nodes, nodes)
    |> assign(:workloads, workloads)
    |> assign(:recent_workloads, Enum.take(workloads, 5))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Cluster Dashboard</h1>
        <span class="text-sm text-base-content/60">
          Auto-refreshes every 5s
        </span>
      </div>

      <!-- Stats Cards -->
      <div class="stats stats-vertical lg:stats-horizontal shadow w-full">
        <div class="stat">
          <div class="stat-figure text-primary">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="inline-block w-8 h-8 stroke-current">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2"></path>
            </svg>
          </div>
          <div class="stat-title">Nodes</div>
          <div class="stat-value text-primary"><%= @status.node_count %></div>
          <div class="stat-desc"><%= @status.nodes_healthy %> healthy</div>
        </div>

        <div class="stat">
          <div class="stat-figure text-secondary">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="inline-block w-8 h-8 stroke-current">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"></path>
            </svg>
          </div>
          <div class="stat-title">Workloads</div>
          <div class="stat-value text-secondary"><%= @status.workload_count %></div>
          <div class="stat-desc"><%= @status.workloads_running %> running</div>
        </div>

        <div class="stat">
          <div class="stat-figure text-accent">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="inline-block w-8 h-8 stroke-current">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 19h10a2 2 0 002-2V7a2 2 0 00-2-2H7a2 2 0 00-2 2v10a2 2 0 002 2zM9 9h6v6H9V9z"></path>
            </svg>
          </div>
          <div class="stat-title">CPU</div>
          <div class="stat-value text-accent"><%= @status.available_cpu %>/<%= @status.total_cpu %></div>
          <div class="stat-desc">cores available</div>
        </div>

        <div class="stat">
          <div class="stat-figure text-info">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="inline-block w-8 h-8 stroke-current">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4"></path>
            </svg>
          </div>
          <div class="stat-title">Memory</div>
          <div class="stat-value text-info"><%= format_memory(@status.available_memory) %></div>
          <div class="stat-desc">of <%= format_memory(@status.total_memory) %> available</div>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <!-- Nodes Panel -->
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <div class="flex justify-between items-center">
              <h2 class="card-title">Nodes</h2>
              <.link navigate={~p"/nodes"} class="btn btn-ghost btn-sm">View All</.link>
            </div>
            <div class="overflow-x-auto">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th>Hostname</th>
                    <th>Status</th>
                    <th>Resources</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for node <- @nodes do %>
                    <tr>
                      <td class="font-mono text-sm"><%= node.hostname %></td>
                      <td>
                        <span class={node_status_badge(node.status)}>
                          <%= node.status %>
                        </span>
                      </td>
                      <td class="text-sm">
                        <%= node.cpu_total - node.cpu_used %>/<%= node.cpu_total %> CPU,
                        <%= format_memory(node.memory_total - node.memory_used) %>/<%= format_memory(node.memory_total) %>
                      </td>
                    </tr>
                  <% end %>
                  <%= if @nodes == [] do %>
                    <tr>
                      <td colspan="3" class="text-center text-base-content/60">No nodes connected</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <!-- Recent Workloads Panel -->
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <div class="flex justify-between items-center">
              <h2 class="card-title">Recent Workloads</h2>
              <.link navigate={~p"/workloads"} class="btn btn-ghost btn-sm">View All</.link>
            </div>
            <div class="overflow-x-auto">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>Type</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for workload <- @recent_workloads do %>
                    <tr>
                      <td class="font-mono text-sm"><%= String.slice(workload.id, 0..7) %></td>
                      <td><%= workload.type %></td>
                      <td>
                        <span class={status_badge_class(workload.status)}>
                          <%= workload.status %>
                        </span>
                      </td>
                    </tr>
                  <% end %>
                  <%= if @recent_workloads == [] do %>
                    <tr>
                      <td colspan="3" class="text-center text-base-content/60">No workloads</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_memory(mb) when is_number(mb) and mb >= 1024 do
    "#{Float.round(mb / 1024, 1)} GB"
  end

  defp format_memory(mb) when is_number(mb), do: "#{mb} MB"
  defp format_memory(_), do: "0 MB"

  defp node_status_badge("available"), do: "badge badge-success"
  defp node_status_badge("unavailable"), do: "badge badge-error"
  defp node_status_badge("draining"), do: "badge badge-warning"
  defp node_status_badge(_), do: "badge"

  defp status_badge_class("running"), do: "badge badge-success"
  defp status_badge_class("starting"), do: "badge badge-warning"
  defp status_badge_class("stopping"), do: "badge badge-warning"
  defp status_badge_class("stopped"), do: "badge badge-ghost"
  defp status_badge_class("failed"), do: "badge badge-error"
  defp status_badge_class("pending"), do: "badge badge-info"
  defp status_badge_class(_), do: "badge"
end
