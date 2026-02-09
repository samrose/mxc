defmodule Mxc.Coordinator.Schemas.WorkloadEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :event_type,
             :metadata,
             :workload_id,
             :inserted_at
           ]}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workload_events" do
    field :event_type, :string
    field :metadata, :map, default: %{}

    belongs_to :workload, Mxc.Coordinator.Schemas.Workload

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required_fields ~w(event_type workload_id)a
  @optional_fields ~w(metadata)a

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:workload_id)
  end
end
