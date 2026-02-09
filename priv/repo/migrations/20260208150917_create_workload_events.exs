defmodule Mxc.Repo.Migrations.CreateWorkloadEvents do
  use Ecto.Migration

  def change do
    create table(:workload_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_type, :string, null: false
      add :metadata, :map, default: %{}
      add :workload_id, references(:workloads, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:workload_events, [:workload_id])
  end
end
