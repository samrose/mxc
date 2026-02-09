defmodule Mxc.Repo.Migrations.CreateNodes do
  use Ecto.Migration

  def change do
    create table(:nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :hostname, :string, null: false
      add :status, :string, null: false, default: "available"
      add :cpu_total, :integer, null: false, default: 0
      add :memory_total, :integer, null: false, default: 0
      add :cpu_used, :integer, null: false, default: 0
      add :memory_used, :integer, null: false, default: 0
      add :hypervisor, :string
      add :capabilities, :map, default: %{}
      add :last_heartbeat_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:nodes, [:hostname])
  end
end
