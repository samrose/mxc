defmodule Mxc.Platform do
  @moduledoc """
  Detects the host platform and available hypervisors.

  Used to validate workload types and set node capabilities
  based on what the current machine can actually run.
  """

  @doc """
  Returns the host OS as an atom: :darwin or :linux.
  """
  def os do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:unix, :linux} -> :linux
      {:unix, other} -> other
      {other, _} -> other
    end
  end

  @doc """
  Returns the host CPU architecture: :aarch64 or :x86_64.
  """
  def arch do
    arch_str = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      String.contains?(arch_str, "aarch64") -> :aarch64
      String.contains?(arch_str, "arm") -> :aarch64
      String.contains?(arch_str, "x86_64") -> :x86_64
      true -> :unknown
    end
  end

  @doc """
  Returns the guest system string for microvm.nix configurations.
  e.g. "aarch64" or "x86_64" — used to select the right nixosConfiguration.
  """
  def guest_arch do
    case arch() do
      :aarch64 -> "aarch64"
      :x86_64 -> "x86_64"
      other -> to_string(other)
    end
  end

  @doc """
  Returns a list of hypervisors available on this system.
  Checks for actual binaries in PATH.
  """
  def available_hypervisors do
    candidates =
      case os() do
        :darwin -> [:qemu, :vfkit]
        :linux -> [:qemu, :cloud_hypervisor, :firecracker]
        _ -> [:qemu]
      end

    Enum.filter(candidates, &hypervisor_available?/1)
  end

  @doc """
  Returns the preferred hypervisor for this platform,
  or nil if none is available.
  """
  def preferred_hypervisor do
    case os() do
      :darwin ->
        cond do
          hypervisor_available?(:qemu) -> :qemu
          hypervisor_available?(:vfkit) -> :vfkit
          true -> nil
        end

      :linux ->
        cond do
          hypervisor_available?(:cloud_hypervisor) -> :cloud_hypervisor
          hypervisor_available?(:qemu) -> :qemu
          hypervisor_available?(:firecracker) -> :firecracker
          true -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Returns whether nix is available (required for microvm workloads).
  """
  def nix_available? do
    System.find_executable("nix") != nil
  end

  @doc """
  Returns true if this platform can run microvm workloads.
  Requires nix and at least one hypervisor.
  """
  def can_run_microvms? do
    nix_available?() and available_hypervisors() != []
  end

  @doc """
  Returns true if this platform can run process workloads.
  Always true — erlexec works everywhere.
  """
  def can_run_processes? do
    true
  end

  @doc """
  Validates a workload type against platform capabilities.
  Returns :ok or {:error, reason}.
  """
  def validate_workload_type("process"), do: :ok

  def validate_workload_type("microvm") do
    cond do
      not nix_available?() ->
        {:error, "nix is required for microvm workloads but is not installed"}

      available_hypervisors() == [] ->
        {:error, "no hypervisor available for microvm workloads on #{os()}/#{arch()}"}

      true ->
        :ok
    end
  end

  def validate_workload_type(type) do
    {:error, "unknown workload type: #{type}"}
  end

  @doc """
  Returns node capabilities map based on platform detection.
  Used when auto-registering the local node.
  """
  def node_capabilities do
    caps = %{
      "os" => to_string(os()),
      "arch" => to_string(arch()),
      "nix" => to_string(nix_available?()),
      "process" => "true"
    }

    hypervisors = available_hypervisors()

    caps =
      if hypervisors != [] do
        Map.put(caps, "microvm", "true")
      else
        caps
      end

    Enum.reduce(hypervisors, caps, fn hv, acc ->
      Map.put(acc, "hypervisor_#{hv}", "true")
    end)
  end

  # Private

  defp hypervisor_available?(:qemu) do
    System.find_executable("qemu-system-aarch64") != nil or
      System.find_executable("qemu-system-x86_64") != nil
  end

  defp hypervisor_available?(:cloud_hypervisor) do
    System.find_executable("cloud-hypervisor") != nil
  end

  defp hypervisor_available?(:firecracker) do
    System.find_executable("firecracker") != nil
  end

  defp hypervisor_available?(:vfkit) do
    System.find_executable("vfkit") != nil
  end

  defp hypervisor_available?(_), do: false
end
