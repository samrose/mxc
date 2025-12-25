defmodule Mxc.Agent.VMManager do
  @moduledoc """
  Manages microVM lifecycle using the configured hypervisor.

  Supports:
  - cloud-hypervisor - Modern, lightweight VMM
  - qemu - Full-featured emulator
  - vfkit - macOS Virtualization.framework wrapper
  """

  require Logger

  @doc """
  Returns whether VM support is available on this system.
  """
  def available? do
    case Application.get_env(:mxc, :hypervisor) do
      nil -> false
      hypervisor -> hypervisor_available?(hypervisor)
    end
  end

  @doc """
  Starts a microVM with the given specification.
  """
  def start_vm(spec) do
    hypervisor = Application.get_env(:mxc, :hypervisor)

    unless hypervisor do
      {:error, :no_hypervisor_configured}
    else
      do_start_vm(hypervisor, spec)
    end
  end

  @doc """
  Stops a running microVM.
  """
  def stop_vm(vm_state) do
    hypervisor = Application.get_env(:mxc, :hypervisor)
    do_stop_vm(hypervisor, vm_state)
  end

  @doc """
  Gets the status of a microVM.
  """
  def vm_status(vm_state) do
    hypervisor = Application.get_env(:mxc, :hypervisor)
    do_vm_status(hypervisor, vm_state)
  end

  # Private - Hypervisor availability checks

  defp hypervisor_available?(:cloud_hypervisor) do
    case System.find_executable("cloud-hypervisor") do
      nil -> false
      _ -> true
    end
  end

  defp hypervisor_available?(:qemu) do
    case System.find_executable("qemu-system-x86_64") || System.find_executable("qemu-system-aarch64") do
      nil -> false
      _ -> true
    end
  end

  defp hypervisor_available?(:vfkit) do
    case System.find_executable("vfkit") do
      nil -> false
      _ -> true
    end
  end

  defp hypervisor_available?(_), do: false

  # Private - Start VM implementations

  defp do_start_vm(:cloud_hypervisor, spec) do
    kernel = spec[:kernel] || raise "microvm requires :kernel path"
    vcpus = spec[:vcpus] || 2
    memory = spec[:memory_mb] || 512

    args = [
      "--kernel", kernel,
      "--cpus", "boot=#{vcpus}",
      "--memory", "size=#{memory}M",
      "--console", "off",
      "--serial", "tty"
    ]

    # Add disk if specified
    args =
      if spec[:disk] do
        args ++ ["--disk", "path=#{spec[:disk]}"]
      else
        args
      end

    # Add network if specified
    args =
      if spec[:tap_device] do
        args ++ ["--net", "tap=#{spec[:tap_device]}"]
      else
        args
      end

    # Add initrd if specified
    args =
      if spec[:initrd] do
        args ++ ["--initramfs", spec[:initrd]]
      else
        args
      end

    # Add kernel command line if specified
    args =
      if spec[:cmdline] do
        args ++ ["--cmdline", spec[:cmdline]]
      else
        args
      end

    cmd = "cloud-hypervisor"
    full_args = Enum.join(args, " ")

    Logger.info("Starting cloud-hypervisor: #{cmd} #{full_args}")

    case :exec.run_link(
           ~c"#{cmd} #{full_args}",
           [:stdout, :stderr, :monitor]
         ) do
      {:ok, pid, os_pid} ->
        {:ok, %{hypervisor: :cloud_hypervisor, pid: pid, os_pid: os_pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_start_vm(:qemu, spec) do
    kernel = spec[:kernel] || raise "microvm requires :kernel path"
    vcpus = spec[:vcpus] || 2
    memory = spec[:memory_mb] || 512

    # Detect architecture
    qemu_bin =
      case :erlang.system_info(:system_architecture) do
        arch when arch in [~c"aarch64-apple-darwin", ~c"aarch64-unknown-linux-gnu"] ->
          "qemu-system-aarch64"

        _ ->
          "qemu-system-x86_64"
      end

    args = [
      "-machine", "microvm",
      "-cpu", "host",
      "-enable-kvm",
      "-smp", "#{vcpus}",
      "-m", "#{memory}",
      "-kernel", kernel,
      "-nodefaults",
      "-no-user-config",
      "-nographic",
      "-serial", "stdio"
    ]

    # Add disk if specified
    args =
      if spec[:disk] do
        args ++ ["-drive", "file=#{spec[:disk]},format=raw,if=virtio"]
      else
        args
      end

    # Add network if specified
    args =
      if spec[:tap_device] do
        args ++ ["-netdev", "tap,id=net0,ifname=#{spec[:tap_device]},script=no,downscript=no",
                 "-device", "virtio-net-device,netdev=net0"]
      else
        args
      end

    # Add initrd if specified
    args =
      if spec[:initrd] do
        args ++ ["-initrd", spec[:initrd]]
      else
        args
      end

    # Add kernel command line if specified
    args =
      if spec[:cmdline] do
        args ++ ["-append", spec[:cmdline]]
      else
        args
      end

    full_args = Enum.join(args, " ")

    Logger.info("Starting qemu: #{qemu_bin} #{full_args}")

    case :exec.run_link(
           ~c"#{qemu_bin} #{full_args}",
           [:stdout, :stderr, :monitor]
         ) do
      {:ok, pid, os_pid} ->
        {:ok, %{hypervisor: :qemu, pid: pid, os_pid: os_pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_start_vm(:vfkit, spec) do
    kernel = spec[:kernel] || raise "microvm requires :kernel path"
    vcpus = spec[:vcpus] || 2
    memory = spec[:memory_mb] || 512

    args = [
      "--cpus", "#{vcpus}",
      "--memory", "#{memory}",
      "--bootloader", "linux,kernel=#{kernel}"
    ]

    # Add initrd if specified
    args =
      if spec[:initrd] do
        args ++ ["--bootloader", "initrd=#{spec[:initrd]}"]
      else
        args
      end

    # Add kernel command line if specified
    args =
      if spec[:cmdline] do
        args ++ ["--bootloader", "cmdline=#{spec[:cmdline]}"]
      else
        args
      end

    # Add disk if specified
    args =
      if spec[:disk] do
        args ++ ["--device", "virtio-blk,path=#{spec[:disk]}"]
      else
        args
      end

    full_args = Enum.join(args, " ")

    Logger.info("Starting vfkit: vfkit #{full_args}")

    case :exec.run_link(
           ~c"vfkit #{full_args}",
           [:stdout, :stderr, :monitor]
         ) do
      {:ok, pid, os_pid} ->
        {:ok, %{hypervisor: :vfkit, pid: pid, os_pid: os_pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_start_vm(hypervisor, _spec) do
    {:error, {:unsupported_hypervisor, hypervisor}}
  end

  # Private - Stop VM implementations

  defp do_stop_vm(_hypervisor, %{os_pid: os_pid}) do
    :exec.stop(os_pid)
    :ok
  end

  defp do_stop_vm(_hypervisor, _state) do
    {:error, :invalid_vm_state}
  end

  # Private - VM status implementations

  defp do_vm_status(_hypervisor, %{os_pid: os_pid}) do
    case :exec.status(os_pid) do
      {:status, :running} -> :running
      {:status, {:exit_status, 0}} -> :stopped
      {:status, {:exit_status, _}} -> :failed
      _ -> :unknown
    end
  end

  defp do_vm_status(_hypervisor, _state) do
    :unknown
  end
end
