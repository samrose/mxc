defmodule MxcWeb.WorkloadsLive do
  use MxcWeb, :live_view

  alias Mxc.Coordinator

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    socket =
      socket
      |> assign(:page_title, "Workloads")
      |> assign(:selected_workload, nil)
      |> assign(:show_deploy_modal, false)
      |> assign(:deploy_form, to_form(%{"type" => "process", "command" => "", "cpu" => "1", "memory_mb" => "256"}))
      |> load_workloads()

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => workload_id}, _uri, socket) do
    case Coordinator.get_workload(workload_id) do
      {:ok, workload} ->
        Phoenix.PubSub.subscribe(Mxc.PubSub, "workloads:#{workload_id}")
        {:noreply, assign(socket, :selected_workload, workload)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Workload not found")
         |> push_navigate(to: ~p"/workloads")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :selected_workload, nil)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket = load_workloads(socket)

    socket =
      if socket.assigns.selected_workload do
        case Coordinator.get_workload(socket.assigns.selected_workload.id) do
          {:ok, workload} -> assign(socket, :selected_workload, workload)
          _ -> assign(socket, :selected_workload, nil)
        end
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:workload_status, workload}, socket) do
    {:noreply,
     socket
     |> assign(:selected_workload, workload)
     |> load_workloads()}
  end

  defp load_workloads(socket) do
    workloads = Coordinator.list_workloads()
    assign(socket, :workloads, workloads)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Workloads</h1>
        <button class="btn btn-primary" phx-click="show_deploy_modal">
          Deploy Workload
        </button>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <!-- Workload List -->
        <div class="lg:col-span-2">
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <div class="overflow-x-auto">
                <table class="table">
                  <thead>
                    <tr>
                      <th>ID</th>
                      <th>Type</th>
                      <th>Status</th>
                      <th>Node</th>
                      <th>Started</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for workload <- @workloads do %>
                      <tr
                        class={"hover cursor-pointer #{if @selected_workload && @selected_workload.id == workload.id, do: "bg-base-200"}"}
                        phx-click="select_workload"
                        phx-value-id={workload.id}
                      >
                        <td class="font-mono text-sm"><%= workload.id %></td>
                        <td><%= workload.type %></td>
                        <td>
                          <span class={status_badge_class(workload.status)}>
                            <%= workload.status %>
                          </span>
                        </td>
                        <td class="font-mono text-xs"><%= workload.node || "-" %></td>
                        <td class="text-sm"><%= format_time(workload.started_at) %></td>
                      </tr>
                    <% end %>
                    <%= if @workloads == [] do %>
                      <tr>
                        <td colspan="5" class="text-center text-base-content/60 py-8">
                          No workloads deployed
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>

        <!-- Workload Details -->
        <div class="lg:col-span-1">
          <%= if @selected_workload do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <div class="flex justify-between items-start">
                  <h2 class="card-title text-lg">Workload Details</h2>
                  <%= if @selected_workload.status in [:running, :starting] do %>
                    <button
                      class="btn btn-error btn-sm"
                      phx-click="stop_workload"
                      phx-value-id={@selected_workload.id}
                    >
                      Stop
                    </button>
                  <% end %>
                </div>

                <div class="space-y-4">
                  <div>
                    <label class="text-sm text-base-content/60">ID</label>
                    <p class="font-mono text-sm"><%= @selected_workload.id %></p>
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Type</label>
                    <p><%= @selected_workload.type %></p>
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Status</label>
                    <p>
                      <span class={status_badge_class(@selected_workload.status)}>
                        <%= @selected_workload.status %>
                      </span>
                    </p>
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Node</label>
                    <p class="font-mono text-sm"><%= @selected_workload.node || "(not assigned)" %></p>
                  </div>

                  <%= if @selected_workload.error do %>
                    <div class="alert alert-error">
                      <span><%= @selected_workload.error %></span>
                    </div>
                  <% end %>

                  <div class="divider">Timing</div>

                  <div>
                    <label class="text-sm text-base-content/60">Started At</label>
                    <p class="text-sm"><%= @selected_workload.started_at || "-" %></p>
                  </div>

                  <div>
                    <label class="text-sm text-base-content/60">Stopped At</label>
                    <p class="text-sm"><%= @selected_workload.stopped_at || "-" %></p>
                  </div>

                  <div class="divider">Spec</div>

                  <div>
                    <pre class="bg-base-200 p-2 rounded text-xs overflow-x-auto"><%= Jason.encode!(@selected_workload.spec, pretty: true) %></pre>
                  </div>
                </div>
              </div>
            </div>
          <% else %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body text-center text-base-content/60">
                <p>Select a workload to view details</p>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Deploy Modal -->
      <%= if @show_deploy_modal do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg">Deploy Workload</h3>

            <.form for={@deploy_form} phx-submit="deploy_workload" class="space-y-4 mt-4">
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Type</span>
                </label>
                <select name="type" class="select select-bordered">
                  <option value="process">Process</option>
                  <option value="microvm">MicroVM</option>
                </select>
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">Command</span>
                </label>
                <input
                  type="text"
                  name="command"
                  placeholder="/bin/sleep 60"
                  class="input input-bordered"
                  value={@deploy_form[:command].value}
                />
              </div>

              <div class="grid grid-cols-2 gap-4">
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">CPU Cores</span>
                  </label>
                  <input
                    type="number"
                    name="cpu"
                    class="input input-bordered"
                    value={@deploy_form[:cpu].value}
                  />
                </div>

                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Memory (MB)</span>
                  </label>
                  <input
                    type="number"
                    name="memory_mb"
                    class="input input-bordered"
                    value={@deploy_form[:memory_mb].value}
                  />
                </div>
              </div>

              <div class="modal-action">
                <button type="button" class="btn" phx-click="hide_deploy_modal">Cancel</button>
                <button type="submit" class="btn btn-primary">Deploy</button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="hide_deploy_modal"></div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("select_workload", %{"id" => workload_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/workloads/#{workload_id}")}
  end

  @impl true
  def handle_event("stop_workload", %{"id" => workload_id}, socket) do
    case Coordinator.stop_workload(workload_id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Workload stopping...")
         |> load_workloads()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("show_deploy_modal", _params, socket) do
    {:noreply, assign(socket, :show_deploy_modal, true)}
  end

  @impl true
  def handle_event("hide_deploy_modal", _params, socket) do
    {:noreply, assign(socket, :show_deploy_modal, false)}
  end

  @impl true
  def handle_event("deploy_workload", params, socket) do
    spec = %{
      type: String.to_atom(params["type"]),
      command: params["command"],
      cpu: String.to_integer(params["cpu"] || "1"),
      memory_mb: String.to_integer(params["memory_mb"] || "256")
    }

    case Coordinator.deploy_workload(spec) do
      {:ok, workload} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workload #{workload.id} deployed!")
         |> assign(:show_deploy_modal, false)
         |> load_workloads()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to deploy: #{inspect(reason)}")}
    end
  end

  defp status_badge_class(:running), do: "badge badge-success"
  defp status_badge_class(:starting), do: "badge badge-warning"
  defp status_badge_class(:stopping), do: "badge badge-warning"
  defp status_badge_class(:stopped), do: "badge badge-ghost"
  defp status_badge_class(:failed), do: "badge badge-error"
  defp status_badge_class(:pending), do: "badge badge-info"
  defp status_badge_class(_), do: "badge"

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_time(other), do: to_string(other)
end
