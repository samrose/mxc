defmodule Mxc.Repo.Migrations.AddWorkloadIp do
  use Ecto.Migration

  def change do
    alter table(:workloads) do
      add :ip, :string
    end
  end
end
