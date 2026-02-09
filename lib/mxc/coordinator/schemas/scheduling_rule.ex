defmodule Mxc.Coordinator.Schemas.SchedulingRule do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :description,
             :rule_text,
             :enabled,
             :priority,
             :inserted_at,
             :updated_at
           ]}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "scheduling_rules" do
    field :name, :string
    field :description, :string
    field :rule_text, :string
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name rule_text)a
  @optional_fields ~w(description enabled priority)a

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:name)
  end
end
