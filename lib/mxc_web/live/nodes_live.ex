defmodule MxcWeb.NodesLive do
  use MxcWeb, :live_view

  alias Mxc.Coordinator

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
      Phoenix.PubSub.subscribe(Mxc.PubSub, "cluster:events")
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

    # Refresh selected node if any
    socket =
      if socket.assigns.selected_node do
        case Coordinator.get_node(socket.assigns.selected_node.node) do
          {:ok, node} -> assign(socket, :selected_node, node)
          _ -> assign(socket, :selected_node, nil)
        end
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:node_down, _node}, socket) do
    {:noreply, load_nodes(socket)}
  end

  @impl true
  def handle_info({:node_up, _node}, socket) do
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
          <%= length(@nodes) %> node(s) connected
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
                      <th>Node</th>
                      <th>Status</th>
                      <th>CPU</th>
                      <th>Memory</th>
                      <th>Workloads</th>
                      <th>Hypervisor</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for node <- @nodes do %>
                      <tr
                        class={"hover cursor-pointer #{if @selected_node && @selected_node.node == node.node, do: "bg-base-200"}"}
                        phx-click="select_node"
                        phx-value-node={node.node}
                      >
                        <td class="font-mono text-sm"><%= node.node %></td>
                        <td>
                          <%= if node.healthy do %>
                            <span class="badge badge-success badge-sm">healthy</span>
                          <% else %>
                            <span class="badge badge-error badge-sm">unhealthy</span>
                          <% end %>
                        </td>
                        <td>
                          <div class="flex items-center gap-2">
                            <progress
                              class="progress progress-primary w-16"
                              value={node.cpu_cores - node.available_cpu}
                              max={node.cpu_cores}
                            />
                            <span class="text-xs"><%= node.available_cpu %>/<%= node.cpu_cores %></span>
                          </div>
                        </td>
                        <td>
                          <div class="flex items-center gap-2">
                            <progress
                              class="progress progress-secondary w-16"
                              value={node.memory_mb - node.available_memory_mb}
                              max={node.memory_mb}
                            />
                            <span class="text-xs"><%= format_memory(node.available_memory_mb) %></span>
                          </div>
                        </td>
                        <td><%= length(node.workloads || []) %></td>
                        <td><%= node.hypervisor || "-" %></td>
                      </tr>
                    <% end %>
                    <%= if @nodes == [] do %>
                      <tr>
                        <td colspan="6" class="text-center text-base-content/60 py-8">
                          No nodes connected to the cluster
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
                    <label class="text-sm text-base-content/60">Node Name</label>
                    <p class="font-mono text-sm break-all"><%= @selected_node.node %></p>
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Status</label>
                    <p>
                      <%= if @selected_node.healthy do %>
                        <span class="badge badge-success">healthy</span>
                      <% else %>
                        <span class="badge badge-error">unhealthy</span>
                      <% end %>
                    </p>
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Last Heartbeat</label>
                    <p class="text-sm"><%= @selected_node.heartbeat_age_ms %> ms ago</p>
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Connected Since</label>
                    <p class="text-sm"><%= @selected_node.connected_at %></p>
                  </div>

                  <div class="divider">Resources</div>

                  <div>
                    <label class="text-sm text-base-content/60">CPU Cores</label>
                    <p><%= @selected_node.available_cpu %> / <%= @selected_node.cpu_cores %> available</p>
                    <progress
                      class="progress progress-primary w-full"
                      value={@selected_node.cpu_cores - @selected_node.available_cpu}
                      max={@selected_node.cpu_cores}
                    />
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Memory</label>
                    <p><%= format_memory(@selected_node.available_memory_mb) %> / <%= format_memory(@selected_node.memory_mb) %> available</p>
                    <progress
                      class="progress progress-secondary w-full"
                      value={@selected_node.memory_mb - @selected_node.available_memory_mb}
                      max={@selected_node.memory_mb}
                    />
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Hypervisor</label>
                    <p><%= @selected_node.hypervisor || "None" %></p>
                  </div>

                  <div class="divider">Workloads</div>

                  <div>
                    <%= if (@selected_node.workloads || []) != [] do %>
                      <ul class="space-y-1">
                        <%= for workload_id <- @selected_node.workloads do %>
                          <li class="font-mono text-sm">
                            <.link navigate={~p"/workloads/#{workload_id}"} class="link link-primary">
                              <%= workload_id %>
                            </.link>
                          </li>
                        <% end %>
                      </ul>
                    <% else %>
                      <p class="text-base-content/60 text-sm">No workloads running</p>
                    <% end %>
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
  def handle_event("select_node", %{"node" => node_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/nodes/#{node_id}")}
  end

  defp format_memory(mb) when mb >= 1024 do
    "#{Float.round(mb / 1024, 1)} GB"
  end

  defp format_memory(mb), do: "#{mb} MB"
end
