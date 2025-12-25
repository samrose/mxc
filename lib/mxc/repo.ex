defmodule Mxc.Repo do
  use Ecto.Repo,
    otp_app: :mxc,
    adapter: Ecto.Adapters.Postgres
end
