defmodule Mxc.Repo.Migrations.CreateWorkloads do
  use Ecto.Migration

  def change do
    create table(:workloads, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false, default: "process"
      add :status, :string, null: false, default: "pending"
      add :command, :string, null: false
      add :args, {:array, :string}, default: []
      add :env, :map, default: %{}
      add :cpu_required, :integer, null: false, default: 1
      add :memory_required, :integer, null: false, default: 256
      add :constraints, :map, default: %{}
      add :error, :string
      add :started_at, :utc_datetime
      add :stopped_at, :utc_datetime
      add :node_id, references(:nodes, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:workloads, [:node_id])
    create index(:workloads, [:status])
  end
end
