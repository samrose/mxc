defmodule Mxc.Coordinator.Schemas.Node do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :hostname,
             :status,
             :cpu_total,
             :memory_total,
             :cpu_used,
             :memory_used,
             :hypervisor,
             :capabilities,
             :last_heartbeat_at,
             :inserted_at,
             :updated_at
           ]}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "nodes" do
    field :hostname, :string
    field :status, :string, default: "available"
    field :cpu_total, :integer, default: 0
    field :memory_total, :integer, default: 0
    field :cpu_used, :integer, default: 0
    field :memory_used, :integer, default: 0
    field :hypervisor, :string
    field :capabilities, :map, default: %{}
    field :last_heartbeat_at, :utc_datetime

    has_many :workloads, Mxc.Coordinator.Schemas.Workload

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(hostname status cpu_total memory_total cpu_used memory_used)a
  @optional_fields ~w(hypervisor capabilities last_heartbeat_at)a
  @valid_statuses ~w(available unavailable draining)

  def changeset(node, attrs) do
    node
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:hostname)
  end
end
