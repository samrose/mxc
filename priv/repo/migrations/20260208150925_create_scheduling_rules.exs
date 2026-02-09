defmodule Mxc.Repo.Migrations.CreateSchedulingRules do
  use Ecto.Migration

  def change do
    create table(:scheduling_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :rule_text, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :priority, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:scheduling_rules, [:name])
  end
end
