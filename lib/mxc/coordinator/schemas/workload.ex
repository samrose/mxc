defmodule Mxc.Coordinator.Schemas.Workload do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :type,
             :status,
             :command,
             :args,
             :env,
             :cpu_required,
             :memory_required,
             :constraints,
             :error,
             :ip,
             :node_id,
             :started_at,
             :stopped_at,
             :inserted_at,
             :updated_at
           ]}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workloads" do
    field :type, :string, default: "process"
    field :status, :string, default: "pending"
    field :command, :string
    field :args, {:array, :string}, default: []
    field :env, :map, default: %{}
    field :cpu_required, :integer, default: 1
    field :memory_required, :integer, default: 256
    field :constraints, :map, default: %{}
    field :error, :string
    field :ip, :string
    field :started_at, :utc_datetime
    field :stopped_at, :utc_datetime

    belongs_to :node, Mxc.Coordinator.Schemas.Node

    has_many :events, Mxc.Coordinator.Schemas.WorkloadEvent

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(type status command)a
  @optional_fields ~w(args env cpu_required memory_required constraints error ip started_at stopped_at node_id)a
  @valid_types ~w(process microvm)
  @valid_statuses ~w(pending starting running stopping stopped failed)

  def changeset(workload, attrs) do
    workload
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @valid_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> foreign_key_constraint(:node_id)
  end
end
