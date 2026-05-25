# Tests tagged :linux_systemd require a real Linux host with systemd, the
# mxc-vm-helper installed at the configured path, a sudoers entry, and the
# `microvm@.service` stub unit template. They are excluded by default and
# opted into via `mix test --include linux_systemd` (or `just test-linux`,
# which runs them on a remote linux-builder).
ExUnit.start(exclude: [:linux_systemd])
Ecto.Adapters.SQL.Sandbox.mode(Mxc.Repo, :manual)
