defmodule MxcWeb.NodesLive do
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
      |> assign(:page_title, "Nodes")
      |> assign(:selected_node, nil)
      |> load_nodes()

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => node_id}, _uri, socket) do
    case Coordinator.get_node(node_id) do
      {:ok, node} ->
        {:noreply, assign(socket, :selected_node, node)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Node not found")
         |> push_navigate(to: ~p"/nodes")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :selected_node, nil)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket = load_nodes(socket)

    socket =
      if socket.assigns.selected_node do
        case Coordinator.get_node(socket.assigns.selected_node.id) do
          {:ok, node} -> assign(socket, :selected_node, node)
          _ -> assign(socket, :selected_node, nil)
        end
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:fact_change, _, _, _}, socket) do
    {:noreply, load_nodes(socket)}
  end

  defp load_nodes(socket) do
    nodes = Coordinator.list_nodes()
    assign(socket, :nodes, nodes)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Nodes</h1>
        <span class="text-sm text-base-content/60">
          <%= length(@nodes) %> node(s) registered
        </span>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <!-- Node List -->
        <div class="lg:col-span-2">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <div class="overflow-x-auto">
                <table class="table">
                  <thead>
                    <tr>
                      <th>Hostname</th>
                      <th>Status</th>
                      <th>CPU</th>
                      <th>Memory</th>
                      <th>Hypervisor</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for node <- @nodes do %>
                      <tr
                        class={"hover cursor-pointer #{if @selected_node && @selected_node.id == node.id, do: "bg-base-200"}"}
                        phx-click="select_node"
                        phx-value-id={node.id}
                      >
                        <td class="font-mono text-sm"><%= node.hostname %></td>
                        <td>
                          <span class={node_status_badge(node.status)}>
                            <%= node.status %>
                          </span>
                        </td>
                        <td>
                          <div class="flex items-center gap-2">
                            <progress
                              class="progress progress-primary w-16"
                              value={node.cpu_used}
                              max={node.cpu_total}
                            />
                            <span class="text-xs"><%= node.cpu_total - node.cpu_used %>/<%= node.cpu_total %></span>
                          </div>
                        </td>
                        <td>
                          <div class="flex items-center gap-2">
                            <progress
                              class="progress progress-secondary w-16"
                              value={node.memory_used}
                              max={node.memory_total}
                            />
                            <span class="text-xs"><%= format_memory(node.memory_total - node.memory_used) %></span>
                          </div>
                        </td>
                        <td><%= node.hypervisor || "-" %></td>
                      </tr>
                    <% end %>
                    <%= if @nodes == [] do %>
                      <tr>
                        <td colspan="5" class="text-center text-base-content/60 py-8">
                          No nodes registered in the cluster
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>

        <!-- Node Details -->
        <div class="lg:col-span-1">
          <%= if @selected_node do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title text-lg">Node Details</h2>

                <div class="space-y-4">
                  <div>
                    <label class="text-sm text-base-content/60">Hostname</label>
                    <p class="font-mono text-sm break-all"><%= @selected_node.hostname %></p>
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Status</label>
                    <p>
                      <span class={node_status_badge(@selected_node.status)}>
                        <%= @selected_node.status %>
                      </span>
                    </p>
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Last Heartbeat</label>
                    <p class="text-sm"><%= format_heartbeat(@selected_node.last_heartbeat_at) %></p>
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Registered</label>
                    <p class="text-sm"><%= format_time(@selected_node.inserted_at) %></p>
                  </div>

                  <div class="divider">Resources</div>

                  <div>
                    <label class="text-sm text-base-content/60">CPU Cores</label>
                    <p><%= @selected_node.cpu_total - @selected_node.cpu_used %> / <%= @selected_node.cpu_total %> available</p>
                    <progress
                      class="progress progress-primary w-full"
                      value={@selected_node.cpu_used}
                      max={@selected_node.cpu_total}
                    />
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Memory</label>
                    <p><%= format_memory(@selected_node.memory_total - @selected_node.memory_used) %> / <%= format_memory(@selected_node.memory_total) %> available</p>
                    <progress
                      class="progress progress-secondary w-full"
                      value={@selected_node.memory_used}
                      max={@selected_node.memory_total}
                    />
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Hypervisor</label>
                    <p><%= @selected_node.hypervisor || "None" %></p>
                  </div>
                </div>
              </div>
            </div>
          <% else %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body text-center text-base-content/60">
                <p>Select a node to view details</p>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("select_node", %{"id" => node_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/nodes/#{node_id}")}
  end

  defp node_status_badge("available"), do: "badge badge-success badge-sm"
  defp node_status_badge("unavailable"), do: "badge badge-error badge-sm"
  defp node_status_badge("draining"), do: "badge badge-warning badge-sm"
  defp node_status_badge(_), do: "badge badge-sm"

  defp format_memory(mb) when is_number(mb) and mb >= 1024 do
    "#{Float.round(mb / 1024, 1)} GB"
  end

  defp format_memory(mb) when is_number(mb), do: "#{mb} MB"
  defp format_memory(_), do: "0 MB"

  defp format_heartbeat(nil), do: "Never"

  defp format_heartbeat(%DateTime{} = dt) do
    age = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      age < 5 -> "just now"
      age < 60 -> "#{age}s ago"
      age < 3600 -> "#{div(age, 60)}m ago"
      true -> "#{div(age, 3600)}h ago"
    end
  end

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_time(other), do: to_string(other)
end
