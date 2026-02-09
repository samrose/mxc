# Datalox Rules Engine Integration Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace mxc's hardcoded coordinator business logic (scheduler, node manager, workload lifecycle) with a datalox-powered rules engine backed by PostgreSQL persistence.

**Architecture:** PostgreSQL is the source of truth for all domain state via Ecto schemas. datalox runs as an in-memory ETS-backed reasoning engine. Ecto records are projected into normalized facts on startup and kept in sync via PubSub + periodic diff-based reconciliation. A Reactor GenServer subscribes to datalox derived facts and executes side effects.

**Tech Stack:** Elixir 1.18, Phoenix 1.8, Ecto 3.13, datalox (git dep from github:samrose/datalox), PostgreSQL 16, Nix dev shell

**Important:** All commands run via `nix develop -c <command>`. No commits unless explicitly asked.

**Design doc:** `docs/plans/2026-02-08-datalox-rules-engine-design.md`

---

### Task 1: Bump Elixir to 1.18 and add datalox dependency

datalox requires Elixir >= 1.18. Current project uses 1.17 (Nix) and `~> 1.15` (mix.exs).

**Files:**
- Modify: `flake.nix:24` — change `elixir_1_17` to `elixir_1_18`
- Modify: `mix.exs:8` — change `"~> 1.15"` to `"~> 1.18"`
- Modify: `mix.exs:65-93` — add datalox to deps

**Step 1: Update flake.nix Elixir version**

In `flake.nix` line 24, change:
```nix
elixir = beamPackages.elixir_1_17;
```
to:
```nix
elixir = beamPackages.elixir_1_18;
```

**Step 2: Update mix.exs Elixir requirement and add datalox**

In `mix.exs` line 8, change:
```elixir
elixir: "~> 1.15",
```
to:
```elixir
elixir: "~> 1.18",
```

In `mix.exs` deps, add after the erlexec line:
```elixir
# Rules engine
{:datalox, github: "samrose/datalox"}
```

**Step 3: Fetch deps and verify compilation**

Run: `nix develop -c mix deps.get`
Expected: datalox fetched from GitHub

Run: `nix develop -c mix compile`
Expected: Clean compilation with no errors

---

### Task 2: Create Ecto schemas and migrations

Create the four domain tables: nodes, workloads, workload_events, scheduling_rules.

**Files:**
- Create: `lib/mxc/coordinator/schemas/node.ex`
- Create: `lib/mxc/coordinator/schemas/workload.ex`
- Create: `lib/mxc/coordinator/schemas/workload_event.ex`
- Create: `lib/mxc/coordinator/schemas/scheduling_rule.ex`
- Create: 4 migration files in `priv/repo/migrations/`

**Step 1: Write test for Node schema**

Create `test/mxc/coordinator/schemas/node_test.exs`:
```elixir
defmodule Mxc.Coordinator.Schemas.NodeTest do
  use Mxc.DataCase, async: true

  alias Mxc.Coordinator.Schemas.Node

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        hostname: "agent1.local",
        status: "available",
        cpu_total: 8,
        memory_total: 16384,
        cpu_used: 0,
        memory_used: 0
      }

      changeset = Node.changeset(%Node{}, attrs)
      assert changeset.valid?
    end

    test "invalid without hostname" do
      changeset = Node.changeset(%Node{}, %{status: "available"})
      refute changeset.valid?
      assert %{hostname: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates status is one of allowed values" do
      attrs = %{hostname: "test", status: "bogus", cpu_total: 1, memory_total: 1024, cpu_used: 0, memory_used: 0}
      changeset = Node.changeset(%Node{}, attrs)
      refute changeset.valid?
    end
  end
end
```

**Step 2: Create Node schema**

Create `lib/mxc/coordinator/schemas/node.ex`:
```elixir
defmodule Mxc.Coordinator.Schemas.Node do
  use Ecto.Schema
  import Ecto.Changeset

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
```

**Step 3: Write test for Workload schema**

Create `test/mxc/coordinator/schemas/workload_test.exs`:
```elixir
defmodule Mxc.Coordinator.Schemas.WorkloadTest do
  use Mxc.DataCase, async: true

  alias Mxc.Coordinator.Schemas.Workload

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        type: "process",
        status: "pending",
        command: "echo hello",
        cpu_required: 1,
        memory_required: 256
      }

      changeset = Workload.changeset(%Workload{}, attrs)
      assert changeset.valid?
    end

    test "invalid without command" do
      attrs = %{type: "process", status: "pending"}
      changeset = Workload.changeset(%Workload{}, attrs)
      refute changeset.valid?
    end

    test "validates type is process or microvm" do
      attrs = %{type: "invalid", status: "pending", command: "echo"}
      changeset = Workload.changeset(%Workload{}, attrs)
      refute changeset.valid?
    end
  end
end
```

**Step 4: Create Workload schema**

Create `lib/mxc/coordinator/schemas/workload.ex`:
```elixir
defmodule Mxc.Coordinator.Schemas.Workload do
  use Ecto.Schema
  import Ecto.Changeset

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
    field :started_at, :utc_datetime
    field :stopped_at, :utc_datetime

    belongs_to :node, Mxc.Coordinator.Schemas.Node

    has_many :events, Mxc.Coordinator.Schemas.WorkloadEvent

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(type status command)a
  @optional_fields ~w(args env cpu_required memory_required constraints error started_at stopped_at node_id)a
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
```

**Step 5: Create WorkloadEvent schema**

Create `lib/mxc/coordinator/schemas/workload_event.ex`:
```elixir
defmodule Mxc.Coordinator.Schemas.WorkloadEvent do
  use Ecto.Schema
  import Ecto.Changeset

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
```

**Step 6: Create SchedulingRule schema**

Create `lib/mxc/coordinator/schemas/scheduling_rule.ex`:
```elixir
defmodule Mxc.Coordinator.Schemas.SchedulingRule do
  use Ecto.Schema
  import Ecto.Changeset

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
```

**Step 7: Create migrations**

Run: `nix develop -c mix ecto.gen.migration create_nodes`

Edit the generated migration file:
```elixir
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
```

Run: `nix develop -c mix ecto.gen.migration create_workloads`

Edit:
```elixir
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
```

Run: `nix develop -c mix ecto.gen.migration create_workload_events`

Edit:
```elixir
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
```

Run: `nix develop -c mix ecto.gen.migration create_scheduling_rules`

Edit:
```elixir
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
```

**Step 8: Run migrations and tests**

Run: `nix develop -c bash -c "mix ecto.create && mix ecto.migrate"`
Expected: 4 tables created

Run: `nix develop -c mix test test/mxc/coordinator/schemas/`
Expected: All schema tests pass

---

### Task 3: Create FactProjection module

Pure functions that map Ecto structs to normalized datalox fact tuples.

**Files:**
- Create: `lib/mxc/coordinator/fact_projection.ex`
- Create: `test/mxc/coordinator/fact_projection_test.exs`

**Step 1: Write test for FactProjection**

Create `test/mxc/coordinator/fact_projection_test.exs`:
```elixir
defmodule Mxc.Coordinator.FactProjectionTest do
  use ExUnit.Case, async: true

  alias Mxc.Coordinator.FactProjection
  alias Mxc.Coordinator.Schemas.{Node, Workload}

  describe "project/1 for Node" do
    test "projects node into normalized facts" do
      node = %Node{
        id: "node-1",
        hostname: "agent1.local",
        status: "available",
        cpu_total: 8,
        memory_total: 16384,
        cpu_used: 2,
        memory_used: 4096,
        hypervisor: "qemu",
        capabilities: %{"gpu" => "a100", "storage" => "ssd"},
        last_heartbeat_at: ~U[2026-02-08 12:00:00Z]
      }

      facts = FactProjection.project(node)

      assert {:node, "node-1", "agent1.local", :available} in facts
      assert {:node_resources, "node-1", 8, 16384} in facts
      assert {:node_resources_used, "node-1", 2, 4096} in facts
      assert {:node_heartbeat, "node-1", _unix} = Enum.find(facts, &match?({:node_heartbeat, _, _}, &1))
      assert {:node_capability, "node-1", "gpu", "a100"} in facts
      assert {:node_capability, "node-1", "storage", "ssd"} in facts
    end

    test "projects node without capabilities" do
      node = %Node{
        id: "node-2",
        hostname: "agent2.local",
        status: "unavailable",
        cpu_total: 4,
        memory_total: 8192,
        cpu_used: 0,
        memory_used: 0,
        capabilities: %{},
        last_heartbeat_at: ~U[2026-02-08 12:00:00Z]
      }

      facts = FactProjection.project(node)
      refute Enum.any?(facts, &match?({:node_capability, _, _, _}, &1))
    end

    test "handles nil hypervisor" do
      node = %Node{
        id: "node-3",
        hostname: "agent3.local",
        status: "available",
        cpu_total: 4,
        memory_total: 8192,
        cpu_used: 0,
        memory_used: 0,
        hypervisor: nil,
        capabilities: %{},
        last_heartbeat_at: ~U[2026-02-08 12:00:00Z]
      }

      facts = FactProjection.project(node)
      refute Enum.any?(facts, &match?({:node_capability, _, :hypervisor, _}, &1))
    end
  end

  describe "project/1 for Workload" do
    test "projects workload with placement" do
      workload = %Workload{
        id: "wl-1",
        type: "process",
        status: "running",
        node_id: "node-1",
        cpu_required: 2,
        memory_required: 512,
        constraints: %{"hypervisor" => "qemu"}
      }

      facts = FactProjection.project(workload)

      assert {:workload, "wl-1", :process, :running} in facts
      assert {:workload_placement, "wl-1", "node-1"} in facts
      assert {:workload_resources, "wl-1", 2, 512} in facts
      assert {:workload_constraint, "wl-1", "hypervisor", "qemu"} in facts
    end

    test "projects workload without placement" do
      workload = %Workload{
        id: "wl-2",
        type: "process",
        status: "pending",
        node_id: nil,
        cpu_required: 1,
        memory_required: 256,
        constraints: %{}
      }

      facts = FactProjection.project(workload)

      assert {:workload, "wl-2", :process, :pending} in facts
      refute Enum.any?(facts, &match?({:workload_placement, _, _}, &1))
    end
  end

  describe "diff/2" do
    test "returns facts to assert and retract" do
      current = [
        {:node, "n1", "host1", :available},
        {:node, "n2", "host2", :available}
      ]

      desired = [
        {:node, "n1", "host1", :available},
        {:node, "n3", "host3", :available}
      ]

      {to_assert, to_retract} = FactProjection.diff(current, desired)

      assert {:node, "n3", "host3", :available} in to_assert
      assert {:node, "n2", "host2", :available} in to_retract
      refute {:node, "n1", "host1", :available} in to_assert
    end
  end
end
```

**Step 2: Implement FactProjection**

Create `lib/mxc/coordinator/fact_projection.ex`:
```elixir
defmodule Mxc.Coordinator.FactProjection do
  @moduledoc """
  Pure functions that map Ecto structs to normalized datalox fact tuples.

  Each domain entity is projected into multiple narrow facts optimized
  for rule composition via joins.
  """

  alias Mxc.Coordinator.Schemas.{Node, Workload, WorkloadEvent}

  @doc """
  Projects an Ecto struct into a list of normalized fact tuples.
  """
  def project(%Node{} = node) do
    base = [
      {:node, node.id, node.hostname, String.to_atom(node.status)},
      {:node_resources, node.id, node.cpu_total, node.memory_total},
      {:node_resources_used, node.id, node.cpu_used, node.memory_used}
    ]

    heartbeat =
      if node.last_heartbeat_at do
        [{:node_heartbeat, node.id, DateTime.to_unix(node.last_heartbeat_at)}]
      else
        []
      end

    hypervisor =
      if node.hypervisor do
        [{:node_capability, node.id, :hypervisor, String.to_atom(node.hypervisor)}]
      else
        []
      end

    capabilities =
      (node.capabilities || %{})
      |> Enum.map(fn {k, v} -> {:node_capability, node.id, k, v} end)

    base ++ heartbeat ++ hypervisor ++ capabilities
  end

  def project(%Workload{} = wl) do
    base = [
      {:workload, wl.id, String.to_atom(wl.type), String.to_atom(wl.status)},
      {:workload_resources, wl.id, wl.cpu_required, wl.memory_required}
    ]

    placement =
      if wl.node_id do
        [{:workload_placement, wl.id, wl.node_id}]
      else
        []
      end

    constraints =
      (wl.constraints || %{})
      |> Enum.map(fn {k, v} -> {:workload_constraint, wl.id, k, v} end)

    base ++ placement ++ constraints
  end

  def project(%WorkloadEvent{} = event) do
    [{:workload_event, event.workload_id, event.event_type, DateTime.to_unix(event.inserted_at)}]
  end

  @doc """
  Computes the diff between current facts in datalox and desired facts from Postgres.
  Returns {facts_to_assert, facts_to_retract}.
  """
  def diff(current_facts, desired_facts) do
    current_set = MapSet.new(current_facts)
    desired_set = MapSet.new(desired_facts)

    to_assert = MapSet.difference(desired_set, current_set) |> MapSet.to_list()
    to_retract = MapSet.difference(current_set, desired_set) |> MapSet.to_list()

    {to_assert, to_retract}
  end
end
```

**Step 3: Run tests**

Run: `nix develop -c mix test test/mxc/coordinator/fact_projection_test.exs`
Expected: All tests pass

---

### Task 4: Create shipped Datalog rules

The core rules that define scheduling, lifecycle, and health logic.

**Files:**
- Create: `priv/rules/scheduling.dl`
- Create: `priv/rules/lifecycle.dl`
- Create: `priv/rules/health.dl`

**Step 1: Create rules directory**

Run: `mkdir -p priv/rules`

**Step 2: Create scheduling.dl**

Create `priv/rules/scheduling.dl`:
```datalog
% A node is healthy if it has heartbeated within 30 seconds
node_healthy(Node) :-
    node(Node, _, :available),
    node_heartbeat(Node, LastSeen),
    now(Now),
    Now - LastSeen < 30.

% Available resources on a node
node_resources_free(Node, CpuFree, MemFree) :-
    node_resources(Node, CpuTotal, MemTotal),
    node_resources_used(Node, CpuUsed, MemUsed),
    CpuFree = CpuTotal - CpuUsed,
    MemFree = MemTotal - MemUsed.

% A node can accept a workload if healthy, has capacity, and meets constraints
can_place(Workload, Node) :-
    workload(Workload, _, :pending),
    workload_resources(Workload, CpuReq, MemReq),
    node_healthy(Node),
    node_resources_free(Node, CpuFree, MemFree),
    CpuFree >= CpuReq,
    MemFree >= MemReq,
    not constraint_violated(Workload, Node).

% A constraint is violated when a workload requires a capability the node lacks
constraint_violated(Workload, Node) :-
    workload_constraint(Workload, CapType, CapValue),
    not node_capability(Node, CapType, CapValue).

% Placement candidates with available resources for strategy selection
placement_candidate(Workload, Node, CpuFree, MemFree) :-
    can_place(Workload, Node),
    node_resources_free(Node, CpuFree, MemFree).
```

**Step 3: Create lifecycle.dl**

Create `priv/rules/lifecycle.dl`:
```datalog
% Valid state transitions
valid_transition(:pending, :starting).
valid_transition(:starting, :running).
valid_transition(:running, :stopping).
valid_transition(:stopping, :stopped).
valid_transition(:starting, :failed).
valid_transition(:running, :failed).

% A workload can transition when the transition is valid
can_transition(Workload, NextStatus) :-
    workload(Workload, _, CurrentStatus),
    valid_transition(CurrentStatus, NextStatus).

% A workload should be marked failed if its node is unhealthy
should_fail(Workload) :-
    workload(Workload, _, :running),
    workload_placement(Workload, Node),
    not node_healthy(Node).

% A workload is restartable if it failed and can still be placed
can_restart(Workload) :-
    workload(Workload, _, :failed),
    can_place(Workload, _).
```

**Step 4: Create health.dl**

Create `priv/rules/health.dl`:
```datalog
% Node is stale if heartbeat older than 30s but not yet marked unavailable
node_stale(Node) :-
    node(Node, _, :available),
    node_heartbeat(Node, LastSeen),
    now(Now),
    Now - LastSeen >= 30.

% Node is overloaded if CPU usage exceeds 90%
node_overloaded(Node) :-
    node_resources(Node, CpuTotal, _),
    node_resources_used(Node, CpuUsed, _),
    CpuUsed * 100 / CpuTotal > 90.

% Node is overloaded if memory usage exceeds 90%
node_overloaded(Node) :-
    node_resources(Node, _, MemTotal),
    node_resources_used(Node, _, MemUsed),
    MemUsed * 100 / MemTotal > 90.

% Workload is orphaned if placed on a node that no longer exists
workload_orphaned(Workload) :-
    workload(Workload, _, :running),
    workload_placement(Workload, Node),
    not node(Node, _, _).
```

**Step 5: Verify rules load**

This will be verified in Task 5 when FactStore loads them. For now, verify syntax by checking files exist:

Run: `ls -la priv/rules/`
Expected: scheduling.dl, lifecycle.dl, health.dl

---

### Task 5: Create FactStore GenServer

The central component that manages the datalox database, loads rules, syncs facts from Postgres, and handles time ticks and reconciliation.

**Files:**
- Create: `lib/mxc/coordinator/fact_store.ex`
- Create: `test/mxc/coordinator/fact_store_test.exs`

**Step 1: Write test for FactStore**

Create `test/mxc/coordinator/fact_store_test.exs`:
```elixir
defmodule Mxc.Coordinator.FactStoreTest do
  use Mxc.DataCase, async: false

  alias Mxc.Coordinator.FactStore
  alias Mxc.Coordinator.Schemas.Node
  alias Mxc.Repo

  setup do
    # Start the FactStore for testing
    start_supervised!(FactStore)
    :ok
  end

  describe "query/1" do
    test "returns empty list when no matching facts" do
      assert [] == FactStore.query({:node, :_, :_, :_})
    end
  end

  describe "sync from PubSub" do
    test "asserts facts when node is created in Postgres" do
      {:ok, node} =
        %Node{}
        |> Node.changeset(%{
          hostname: "test-agent",
          status: "available",
          cpu_total: 4,
          memory_total: 8192,
          cpu_used: 0,
          memory_used: 0,
          last_heartbeat_at: DateTime.utc_now()
        })
        |> Repo.insert()

      # Broadcast the fact change (simulating what the Coordinator context would do)
      Phoenix.PubSub.broadcast(Mxc.PubSub, "fact_changes", {:fact_change, :nodes, :insert, node})

      # Give PubSub time to deliver
      Process.sleep(100)

      results = FactStore.query({:node, node.id, :_, :_})
      assert length(results) == 1
    end
  end

  describe "select_node/2" do
    test "returns error when no nodes available" do
      assert {:error, :no_available_nodes} == FactStore.select_node("wl-1", :spread)
    end
  end
end
```

**Step 2: Implement FactStore**

Create `lib/mxc/coordinator/fact_store.ex`:
```elixir
defmodule Mxc.Coordinator.FactStore do
  @moduledoc """
  Manages the datalox database instance for the coordinator.

  Responsibilities:
  - Creates datalox database on init (ETS-backed)
  - Loads shipped rules from priv/rules/*.dl on startup
  - Loads enabled user rules from scheduling_rules table on startup
  - Queries all domain tables and bulk-asserts projected facts on startup
  - Subscribes to PubSub for real-time fact sync on Ecto writes
  - Updates now(Timestamp) fact every 5 seconds
  - Runs diff-based reconciliation every 30 seconds
  - Exposes query API for Reactor and Coordinator context
  """

  use GenServer
  require Logger

  alias Mxc.Coordinator.FactProjection
  alias Mxc.Coordinator.Schemas.{Node, Workload, SchedulingRule}
  alias Mxc.Repo

  import Ecto.Query

  @time_tick_ms 5_000
  @reconcile_ms 30_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Query datalox for facts matching a pattern.
  """
  def query(pattern) do
    GenServer.call(__MODULE__, {:query, pattern})
  end

  @doc """
  Select the best node for a workload using the given strategy.
  """
  def select_node(workload_id, strategy \\ :spread) do
    GenServer.call(__MODULE__, {:select_node, workload_id, strategy})
  end

  @doc """
  Force a reconciliation now (useful for testing).
  """
  def reconcile do
    GenServer.call(__MODULE__, :reconcile)
  end

  @doc """
  Reload user-defined rules from the database.
  """
  def reload_rules do
    GenServer.call(__MODULE__, :reload_rules)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Subscribe to fact changes
    Phoenix.PubSub.subscribe(Mxc.PubSub, "fact_changes")

    # Create datalox database
    db = Datalox.new(name: :mxc_rules)

    # Load shipped rules
    db = load_shipped_rules(db)

    # Load user rules from database
    db = load_user_rules(db)

    # Bulk load all facts from Postgres
    db = load_all_facts(db)

    # Assert initial time fact
    db = assert_now(db)

    # Schedule periodic tasks
    schedule_time_tick()
    schedule_reconciliation()

    Logger.info("FactStore initialized with datalox database")
    {:ok, %{db: db}}
  end

  @impl true
  def handle_call({:query, pattern}, _from, state) do
    results = Datalox.query(state.db, pattern)
    {:reply, results, state}
  end

  @impl true
  def handle_call({:select_node, workload_id, strategy}, _from, state) do
    candidates = Datalox.query(state.db, {:placement_candidate, workload_id, :_, :_, :_})

    result =
      case {candidates, strategy} do
        {[], _} ->
          {:error, :no_available_nodes}

        {list, :spread} ->
          {:ok, Enum.max_by(list, &resource_score/1)}

        {list, :pack} ->
          {:ok, Enum.min_by(list, &resource_score/1)}

        {list, :random} ->
          {:ok, Enum.random(list)}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    db = do_reconcile(state.db)
    {:reply, :ok, %{state | db: db}}
  end

  @impl true
  def handle_call(:reload_rules, _from, state) do
    db = load_user_rules(state.db)
    {:reply, :ok, %{state | db: db}}
  end

  # PubSub handler for fact changes
  @impl true
  def handle_info({:fact_change, _table, :insert, record}, state) do
    facts = FactProjection.project(record)
    db = Datalox.assert_all(state.db, facts)
    {:noreply, %{state | db: db}}
  end

  @impl true
  def handle_info({:fact_change, _table, :update, record}, state) do
    # Retract old facts for this entity, assert new ones
    db = retract_entity_facts(state.db, record)
    facts = FactProjection.project(record)
    db = Datalox.assert_all(db, facts)
    {:noreply, %{state | db: db}}
  end

  @impl true
  def handle_info({:fact_change, _table, :delete, record}, state) do
    db = retract_entity_facts(state.db, record)
    {:noreply, %{state | db: db}}
  end

  @impl true
  def handle_info({:rules_changed}, state) do
    db = load_user_rules(state.db)
    {:noreply, %{state | db: db}}
  end

  @impl true
  def handle_info(:time_tick, state) do
    db = assert_now(state.db)
    schedule_time_tick()
    {:noreply, %{state | db: db}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    db = do_reconcile(state.db)
    schedule_reconciliation()
    {:noreply, %{state | db: db}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp load_shipped_rules(db) do
    rules_dir = Application.app_dir(:mxc, "priv/rules")

    if File.dir?(rules_dir) do
      rules_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".dl"))
      |> Enum.sort()
      |> Enum.reduce(db, fn file, acc ->
        path = Path.join(rules_dir, file)
        Logger.info("Loading shipped rules from #{file}")
        Datalox.load_file(acc, path)
      end)
    else
      Logger.warning("Rules directory not found: #{rules_dir}")
      db
    end
  end

  defp load_user_rules(db) do
    rules =
      SchedulingRule
      |> where([r], r.enabled == true)
      |> order_by([r], asc: r.priority)
      |> Repo.all()

    Enum.reduce(rules, db, fn rule, acc ->
      Logger.info("Loading user rule: #{rule.name}")
      # Load rule text as inline datalog
      Datalox.load_file(acc, {:string, rule.rule_text})
    end)
  rescue
    _ ->
      Logger.warning("Could not load user rules (table may not exist yet)")
      db
  end

  defp load_all_facts(db) do
    nodes = Repo.all(Node)
    workloads = Repo.all(Workload)

    all_facts =
      Enum.flat_map(nodes, &FactProjection.project/1) ++
        Enum.flat_map(workloads, &FactProjection.project/1)

    Datalox.assert_all(db, all_facts)
  rescue
    _ ->
      Logger.warning("Could not load facts from database (tables may not exist yet)")
      db
  end

  defp assert_now(db) do
    # Retract old now fact
    old = Datalox.query(db, {:now, :_})
    db = Enum.reduce(old, db, fn fact, acc -> Datalox.retract(acc, fact) end)

    # Assert new now fact
    Datalox.assert(db, {:now, System.os_time(:second)})
  end

  defp do_reconcile(db) do
    desired_facts =
      Enum.flat_map(Repo.all(Node), &FactProjection.project/1) ++
        Enum.flat_map(Repo.all(Workload), &FactProjection.project/1)

    # Get current domain facts (exclude system facts like now/1 and derived facts)
    current_node_facts = Datalox.query(db, {:node, :_, :_, :_}) ++
      Datalox.query(db, {:node_resources, :_, :_, :_}) ++
      Datalox.query(db, {:node_resources_used, :_, :_, :_}) ++
      Datalox.query(db, {:node_capability, :_, :_, :_}) ++
      Datalox.query(db, {:node_heartbeat, :_, :_})

    current_workload_facts = Datalox.query(db, {:workload, :_, :_, :_}) ++
      Datalox.query(db, {:workload_placement, :_, :_}) ++
      Datalox.query(db, {:workload_resources, :_, :_, :_}) ++
      Datalox.query(db, {:workload_constraint, :_, :_, :_})

    current_facts = current_node_facts ++ current_workload_facts

    {to_assert, to_retract} = FactProjection.diff(current_facts, desired_facts)

    if to_assert != [] or to_retract != [] do
      Logger.info("Reconciliation: asserting #{length(to_assert)}, retracting #{length(to_retract)} facts")
    end

    db = Enum.reduce(to_retract, db, fn fact, acc -> Datalox.retract(acc, fact) end)
    db = Datalox.assert_all(db, to_assert)

    db
  rescue
    _ ->
      Logger.warning("Reconciliation failed (database may not be ready)")
      db
  end

  defp retract_entity_facts(db, %Node{id: id}) do
    facts_to_retract =
      Datalox.query(db, {:node, id, :_, :_}) ++
        Datalox.query(db, {:node_resources, id, :_, :_}) ++
        Datalox.query(db, {:node_resources_used, id, :_, :_}) ++
        Datalox.query(db, {:node_capability, id, :_, :_}) ++
        Datalox.query(db, {:node_heartbeat, id, :_})

    Enum.reduce(facts_to_retract, db, fn fact, acc -> Datalox.retract(acc, fact) end)
  end

  defp retract_entity_facts(db, %Workload{id: id}) do
    facts_to_retract =
      Datalox.query(db, {:workload, id, :_, :_}) ++
        Datalox.query(db, {:workload_placement, id, :_}) ++
        Datalox.query(db, {:workload_resources, id, :_, :_}) ++
        Datalox.query(db, {:workload_constraint, id, :_, :_})

    Enum.reduce(facts_to_retract, db, fn fact, acc -> Datalox.retract(acc, fact) end)
  end

  defp retract_entity_facts(db, _), do: db

  defp resource_score(candidate) do
    {:placement_candidate, _wl, _node, cpu_free, mem_free} = candidate
    cpu_free + mem_free / 1024
  end

  defp schedule_time_tick do
    Process.send_after(self(), :time_tick, @time_tick_ms)
  end

  defp schedule_reconciliation do
    Process.send_after(self(), :reconcile, @reconcile_ms)
  end
end
```

**Step 3: Run tests**

Run: `nix develop -c mix test test/mxc/coordinator/fact_store_test.exs`
Expected: Tests pass (some may need adjustment based on datalox API)

---

### Task 6: Create Reactor GenServer

Subscribes to datalox derived facts and takes actions.

**Files:**
- Create: `lib/mxc/coordinator/reactor.ex`
- Create: `test/mxc/coordinator/reactor_test.exs`

**Step 1: Write test for Reactor**

Create `test/mxc/coordinator/reactor_test.exs`:
```elixir
defmodule Mxc.Coordinator.ReactorTest do
  use Mxc.DataCase, async: false

  alias Mxc.Coordinator.Reactor
  alias Mxc.Coordinator.Schemas.Node
  alias Mxc.Repo

  describe "handle_stale_node/1" do
    test "marks node as unavailable" do
      {:ok, node} =
        %Node{}
        |> Node.changeset(%{
          hostname: "stale-agent",
          status: "available",
          cpu_total: 4,
          memory_total: 8192,
          cpu_used: 0,
          memory_used: 0
        })
        |> Repo.insert()

      Reactor.handle_stale_node(node.id)

      updated = Repo.get!(Node, node.id)
      assert updated.status == "unavailable"
    end
  end
end
```

**Step 2: Implement Reactor**

Create `lib/mxc/coordinator/reactor.ex`:
```elixir
defmodule Mxc.Coordinator.Reactor do
  @moduledoc """
  Subscribes to datalox derived facts and executes side effects.

  The Reactor bridges the gap between declarative rules and imperative actions.
  Rules derive what should happen; the Reactor does the doing.

  All actions are idempotent — duplicate derivations are safe.
  """

  use GenServer
  require Logger

  alias Mxc.Coordinator.FactStore
  alias Mxc.Coordinator.Schemas.{Node, Workload, WorkloadEvent}
  alias Mxc.Repo

  import Ecto.Query

  @check_interval_ms 5_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Handle a stale node (called by check loop or directly for testing).
  """
  def handle_stale_node(node_id) do
    GenServer.cast(__MODULE__, {:handle_stale_node, node_id})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{acted_on: MapSet.new()}}
  end

  @impl true
  def handle_cast({:handle_stale_node, node_id}, state) do
    do_handle_stale_node(node_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_derived_facts, state) do
    state = check_all_derived_facts(state)
    schedule_check()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp check_all_derived_facts(state) do
    state
    |> check_stale_nodes()
    |> check_should_fail()
    |> check_orphaned_workloads()
  end

  defp check_stale_nodes(state) do
    stale = FactStore.query({:node_stale, :_})

    Enum.each(stale, fn {:node_stale, node_id} ->
      do_handle_stale_node(node_id)
    end)

    state
  end

  defp check_should_fail(state) do
    should_fail = FactStore.query({:should_fail, :_})

    Enum.each(should_fail, fn {:should_fail, workload_id} ->
      do_handle_workload_failure(workload_id)
    end)

    state
  end

  defp check_orphaned_workloads(state) do
    orphaned = FactStore.query({:workload_orphaned, :_})

    Enum.each(orphaned, fn {:workload_orphaned, workload_id} ->
      do_handle_orphaned_workload(workload_id)
    end)

    state
  end

  defp do_handle_stale_node(node_id) do
    case Repo.get(Node, node_id) do
      nil ->
        :ok

      %Node{status: "unavailable"} ->
        :ok

      node ->
        Logger.warning("Reactor: marking stale node #{node.hostname} as unavailable")

        node
        |> Node.changeset(%{status: "unavailable"})
        |> Repo.update!()

        broadcast_change(:nodes, :update, node)
    end
  end

  defp do_handle_workload_failure(workload_id) do
    case Repo.get(Workload, workload_id) do
      nil ->
        :ok

      %Workload{status: status} when status in ["failed", "stopped"] ->
        :ok

      workload ->
        Logger.warning("Reactor: marking workload #{workload_id} as failed (node unhealthy)")

        # Try to stop on the agent
        if workload.node_id do
          try_stop_on_agent(workload)
        end

        workload
        |> Workload.changeset(%{status: "failed", error: "Node became unhealthy", stopped_at: DateTime.utc_now()})
        |> Repo.update!()

        insert_event(workload_id, "failed", %{reason: "node_unhealthy"})
        broadcast_change(:workloads, :update, workload)
    end
  end

  defp do_handle_orphaned_workload(workload_id) do
    case Repo.get(Workload, workload_id) do
      nil ->
        :ok

      %Workload{status: status} when status in ["failed", "stopped"] ->
        :ok

      workload ->
        Logger.warning("Reactor: marking orphaned workload #{workload_id} as failed")

        workload
        |> Workload.changeset(%{status: "failed", error: "Node no longer exists", node_id: nil, stopped_at: DateTime.utc_now()})
        |> Repo.update!()

        insert_event(workload_id, "failed", %{reason: "node_removed"})
        broadcast_change(:workloads, :update, workload)
    end
  end

  defp try_stop_on_agent(workload) do
    # Find the node's Erlang node name and send stop command
    case Repo.get(Node, workload.node_id) do
      nil -> :ok
      node ->
        erlang_node = String.to_atom("agent@#{node.hostname}")
        try do
          GenServer.cast({Mxc.Agent.Executor, erlang_node}, {:stop_workload, workload.id})
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp insert_event(workload_id, event_type, metadata) do
    %WorkloadEvent{}
    |> WorkloadEvent.changeset(%{
      workload_id: workload_id,
      event_type: event_type,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp broadcast_change(table, operation, record) do
    Phoenix.PubSub.broadcast(Mxc.PubSub, "fact_changes", {:fact_change, table, operation, record})
  end

  defp schedule_check do
    Process.send_after(self(), :check_derived_facts, @check_interval_ms)
  end
end
```

**Step 3: Run tests**

Run: `nix develop -c mix test test/mxc/coordinator/reactor_test.exs`
Expected: Tests pass

---

### Task 7: Update Coordinator context and Supervisor

Replace GenServer delegates with Ecto queries and FactStore calls.

**Files:**
- Modify: `lib/mxc/coordinator/supervisor.ex`
- Modify: `lib/mxc/coordinator.ex`

**Step 1: Update Supervisor to start FactStore and Reactor**

Replace the children list in `lib/mxc/coordinator/supervisor.ex`:

Replace `Mxc.Coordinator.NodeManager` and `Mxc.Coordinator.Workload` with `Mxc.Coordinator.FactStore` and `Mxc.Coordinator.Reactor`. Keep the Cluster.Supervisor.

New `init/1`:
```elixir
@impl true
def init(_opts) do
  topologies = Mxc.Coordinator.Cluster.topologies()

  children = [
    {Cluster.Supervisor, [topologies, [name: Mxc.ClusterSupervisor]]},
    Mxc.Coordinator.FactStore,
    Mxc.Coordinator.Reactor
  ]

  Supervisor.init(children, strategy: :one_for_one)
end
```

**Step 2: Rewrite Coordinator context**

Replace `lib/mxc/coordinator.ex` to use Ecto for CRUD and FactStore for decisions:

```elixir
defmodule Mxc.Coordinator do
  @moduledoc """
  The Coordinator context manages the cluster of agents and workload scheduling.

  Uses Ecto for CRUD operations (display) and datalox via FactStore for
  rule-based decisions (scheduling, health, lifecycle).
  """

  alias Mxc.Coordinator.FactStore
  alias Mxc.Coordinator.Schemas.{Node, Workload, WorkloadEvent, SchedulingRule}
  alias Mxc.Repo

  import Ecto.Query

  # --- Nodes ---

  def list_nodes do
    Repo.all(Node)
  end

  def get_node(node_id) do
    case Repo.get(Node, node_id) do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  def register_node(attrs) do
    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :hostname, returning: true)
    |> broadcast_change(:nodes, :insert)
  end

  def update_node(%Node{} = node, attrs) do
    node
    |> Node.changeset(attrs)
    |> Repo.update()
    |> broadcast_change(:nodes, :update)
  end

  def heartbeat(node_id, status) do
    case Repo.get(Node, node_id) do
      nil -> {:error, :not_found}
      node ->
        update_node(node, %{
          cpu_used: status[:cpu_used] || node.cpu_used,
          memory_used: status[:memory_used] || node.memory_used,
          last_heartbeat_at: DateTime.utc_now()
        })
    end
  end

  # --- Workloads ---

  def list_workloads do
    Repo.all(Workload)
  end

  def get_workload(id) do
    case Repo.get(Workload, id) do
      nil -> {:error, :not_found}
      workload -> {:ok, workload}
    end
  end

  def deploy_workload(spec) do
    # Create workload in pending state
    with {:ok, workload} <- create_workload(spec),
         # Ask datalox for placement
         {:ok, candidate} <- FactStore.select_node(workload.id, scheduler_strategy()),
         {:placement_candidate, _wl, node_id, _cpu, _mem} <- candidate do
      # Update with placement and start
      workload
      |> Workload.changeset(%{node_id: node_id, status: "starting"})
      |> Repo.update()
      |> broadcast_change(:workloads, :update)
      |> case do
        {:ok, updated} ->
          request_agent_start(updated)
          insert_event(updated.id, "starting", %{node_id: node_id})
          {:ok, updated}

        error ->
          error
      end
    else
      {:error, :no_available_nodes} -> {:error, :no_nodes}
      {:error, _} = error -> error
    end
  end

  def stop_workload(id) do
    case Repo.get(Workload, id) do
      nil ->
        {:error, :not_found}

      workload ->
        workload
        |> Workload.changeset(%{status: "stopping"})
        |> Repo.update()
        |> broadcast_change(:workloads, :update)
        |> case do
          {:ok, updated} ->
            request_agent_stop(updated)
            insert_event(id, "stopping", %{})
            :ok

          error ->
            error
        end
    end
  end

  def update_workload_status(workload_id, status, metadata \\ %{}) do
    case Repo.get(Workload, workload_id) do
      nil -> {:error, :not_found}
      workload ->
        attrs = %{status: to_string(status)}
        attrs = if status == :running, do: Map.put(attrs, :started_at, DateTime.utc_now()), else: attrs
        attrs = if status in [:stopped, :failed], do: Map.put(attrs, :stopped_at, DateTime.utc_now()), else: attrs
        attrs = if metadata[:error], do: Map.put(attrs, :error, metadata[:error]), else: attrs

        workload
        |> Workload.changeset(attrs)
        |> Repo.update()
        |> broadcast_change(:workloads, :update)
        |> tap(fn {:ok, _} -> insert_event(workload_id, to_string(status), metadata); _ -> :ok end)
    end
  end

  # --- Scheduling Rules ---

  def list_rules do
    Repo.all(SchedulingRule)
  end

  def create_rule(attrs) do
    %SchedulingRule{}
    |> SchedulingRule.changeset(attrs)
    |> Repo.insert()
    |> tap(fn {:ok, _} ->
      Phoenix.PubSub.broadcast(Mxc.PubSub, "fact_changes", {:rules_changed})
    end)
  end

  # --- Cluster Status ---

  def cluster_status do
    nodes = list_nodes()
    workloads = list_workloads()

    now = DateTime.utc_now()
    healthy_count = Enum.count(nodes, fn n ->
      n.last_heartbeat_at && DateTime.diff(now, n.last_heartbeat_at, :second) < 30
    end)

    %{
      node_count: length(nodes),
      nodes_healthy: healthy_count,
      workload_count: length(workloads),
      workloads_running: Enum.count(workloads, &(&1.status == "running")),
      total_cpu: Enum.sum(Enum.map(nodes, & &1.cpu_total)),
      total_memory_mb: Enum.sum(Enum.map(nodes, & &1.memory_total)),
      available_cpu: Enum.sum(Enum.map(nodes, &(&1.cpu_total - &1.cpu_used))),
      available_memory_mb: Enum.sum(Enum.map(nodes, &(&1.memory_total - &1.memory_used)))
    }
  end

  # --- Private ---

  defp create_workload(spec) do
    %Workload{}
    |> Workload.changeset(%{
      type: to_string(spec[:type] || :process),
      status: "pending",
      command: spec[:command],
      args: spec[:args] || [],
      env: spec[:env] || %{},
      cpu_required: spec[:cpu] || 1,
      memory_required: spec[:memory_mb] || 256,
      constraints: spec[:constraints] || %{}
    })
    |> Repo.insert()
    |> broadcast_change(:workloads, :insert)
  end

  defp request_agent_start(workload) do
    case Repo.get(Node, workload.node_id) do
      nil -> {:error, :node_not_found}
      node ->
        erlang_node = String.to_atom("agent@#{node.hostname}")
        workload_spec = %{
          id: workload.id,
          type: String.to_atom(workload.type),
          spec: %{
            command: workload.command,
            args: workload.args,
            env: workload.env,
            cpu: workload.cpu_required,
            memory_mb: workload.memory_required
          }
        }
        try do
          GenServer.call({Mxc.Agent.Executor, erlang_node}, {:start_workload, workload_spec})
        catch
          :exit, _ -> {:error, :node_unreachable}
        end
    end
  end

  defp request_agent_stop(workload) do
    if workload.node_id do
      case Repo.get(Node, workload.node_id) do
        nil -> :ok
        node ->
          erlang_node = String.to_atom("agent@#{node.hostname}")
          try do
            GenServer.cast({Mxc.Agent.Executor, erlang_node}, {:stop_workload, workload.id})
          catch
            :exit, _ -> :ok
          end
      end
    end
  end

  defp insert_event(workload_id, event_type, metadata) do
    %WorkloadEvent{}
    |> WorkloadEvent.changeset(%{workload_id: workload_id, event_type: event_type, metadata: metadata})
    |> Repo.insert()
  end

  defp broadcast_change({:ok, record}, table, operation) do
    Phoenix.PubSub.broadcast(Mxc.PubSub, "fact_changes", {:fact_change, table, operation, record})
    {:ok, record}
  end

  defp broadcast_change(other, _table, _operation), do: other

  defp scheduler_strategy do
    Application.get_env(:mxc, :scheduler_strategy, :spread)
  end
end
```

**Step 3: Run all tests**

Run: `nix develop -c mix test`
Expected: Compilation succeeds, tests pass (some existing tests may need updates in Task 8)

---

### Task 8: Update API controllers and LiveViews

Update controllers and LiveViews to work with the new Ecto-based Coordinator context. The API surface stays the same but the data shapes change (Ecto structs instead of plain maps).

**Files:**
- Modify: `lib/mxc_web/controllers/api/node_controller.ex`
- Modify: `lib/mxc_web/controllers/api/workload_controller.ex`
- Modify: `lib/mxc_web/controllers/api/cluster_controller.ex`
- Modify: `lib/mxc_web/live/dashboard_live.ex`
- Modify: `lib/mxc_web/live/nodes_live.ex`
- Modify: `lib/mxc_web/live/workloads_live.ex`

**Step 1: Update NodeController**

The controller needs to handle Ecto structs. Add a `render_node/1` helper to convert structs to JSON-safe maps. The JSON encoder needs to handle Ecto structs — either derive Jason.Encoder on the schemas or convert to maps in the controller.

Add `@derive {Jason.Encoder, only: [...]}` to each schema, or convert in controllers. Converting in controllers is simpler and doesn't couple schemas to JSON:

Update `lib/mxc_web/controllers/api/node_controller.ex`:
```elixir
defmodule MxcWeb.API.NodeController do
  use MxcWeb, :controller

  alias Mxc.Coordinator

  def index(conn, _params) do
    nodes = Coordinator.list_nodes() |> Enum.map(&node_to_map/1)
    json(conn, nodes)
  end

  def show(conn, %{"id" => node_id}) do
    case Coordinator.get_node(node_id) do
      {:ok, node} -> json(conn, node_to_map(node))
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Node not found"})
    end
  end

  defp node_to_map(node) do
    now = DateTime.utc_now()
    heartbeat_age = if node.last_heartbeat_at, do: DateTime.diff(now, node.last_heartbeat_at, :second), else: nil

    %{
      id: node.id,
      hostname: node.hostname,
      status: node.status,
      cpu_total: node.cpu_total,
      memory_total: node.memory_total,
      cpu_used: node.cpu_used,
      memory_used: node.memory_used,
      available_cpu: node.cpu_total - node.cpu_used,
      available_memory_mb: node.memory_total - node.memory_used,
      hypervisor: node.hypervisor,
      capabilities: node.capabilities,
      healthy: heartbeat_age != nil and heartbeat_age < 30,
      heartbeat_age_s: heartbeat_age,
      last_heartbeat_at: node.last_heartbeat_at
    }
  end
end
```

**Step 2: Update WorkloadController**

Update `lib/mxc_web/controllers/api/workload_controller.ex`:
```elixir
defmodule MxcWeb.API.WorkloadController do
  use MxcWeb, :controller

  alias Mxc.Coordinator

  def index(conn, _params) do
    workloads = Coordinator.list_workloads() |> Enum.map(&workload_to_map/1)
    json(conn, workloads)
  end

  def show(conn, %{"id" => workload_id}) do
    case Coordinator.get_workload(workload_id) do
      {:ok, workload} -> json(conn, workload_to_map(workload))
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Workload not found"})
    end
  end

  def create(conn, params) do
    spec = %{
      type: String.to_atom(params["type"] || "process"),
      command: params["command"],
      args: params["args"] || [],
      env: params["env"] || %{},
      cpu: params["cpu"] || 1,
      memory_mb: params["memory_mb"] || 256,
      constraints: params["constraints"] || %{}
    }

    case Coordinator.deploy_workload(spec) do
      {:ok, workload} ->
        conn |> put_status(:created) |> json(workload_to_map(workload))
      {:error, :no_nodes} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "No nodes available"})
      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def stop(conn, %{"id" => workload_id}) do
    case Coordinator.stop_workload(workload_id) do
      :ok -> json(conn, %{status: "stopping"})
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Workload not found"})
      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  defp workload_to_map(wl) do
    %{
      id: wl.id,
      type: wl.type,
      status: wl.status,
      command: wl.command,
      node_id: wl.node_id,
      cpu_required: wl.cpu_required,
      memory_required: wl.memory_required,
      constraints: wl.constraints,
      error: wl.error,
      started_at: wl.started_at,
      stopped_at: wl.stopped_at
    }
  end
end
```

**Step 3: Update DashboardLive**

The main change: node fields use Ecto column names (e.g., `node.cpu_total` instead of `node.cpu_cores`, `node.memory_total` instead of `node.memory_mb`). Health is computed from `last_heartbeat_at` rather than a pre-computed field.

Update `lib/mxc_web/live/dashboard_live.ex` — change the template references:
- `node.cpu_cores` → `node.cpu_total`
- `node.memory_mb` → `node.memory_total`
- `node.available_memory_mb` → `node.memory_total - node.memory_used`
- `node.available_cpu` → `node.cpu_total - node.cpu_used`
- `node.healthy` → computed from `node.last_heartbeat_at`
- `workload.status` is now a string, not atom — update `status_badge_class` to accept strings

Update the `load_data` helper to add computed fields:
```elixir
defp load_data(socket) do
  status = Coordinator.cluster_status()
  nodes = Coordinator.list_nodes() |> Enum.map(&enrich_node/1)
  workloads = Coordinator.list_workloads()

  socket
  |> assign(:status, status)
  |> assign(:nodes, nodes)
  |> assign(:workloads, workloads)
  |> assign(:recent_workloads, Enum.take(workloads, 5))
end

defp enrich_node(node) do
  now = DateTime.utc_now()
  healthy = node.last_heartbeat_at != nil and DateTime.diff(now, node.last_heartbeat_at, :second) < 30

  Map.merge(node, %{healthy: healthy, available_cpu: node.cpu_total - node.cpu_used, available_memory_mb: node.memory_total - node.memory_used})
end
```

Update `status_badge_class` to accept string statuses:
```elixir
defp status_badge_class("running"), do: "badge badge-success"
defp status_badge_class("starting"), do: "badge badge-warning"
defp status_badge_class("stopping"), do: "badge badge-warning"
defp status_badge_class("stopped"), do: "badge badge-ghost"
defp status_badge_class("failed"), do: "badge badge-error"
defp status_badge_class(_), do: "badge"
```

**Step 4: Update NodesLive and WorkloadsLive similarly**

Apply the same field name changes and string-status handling to `nodes_live.ex` and `workloads_live.ex`.

**Step 5: Run all tests**

Run: `nix develop -c mix test`
Expected: All tests pass

Run: `nix develop -c mix compile --warnings-as-errors`
Expected: Clean compilation

---

### Task 9: Update Agent health reporting

The agent's Health GenServer currently sends heartbeats to `Mxc.Coordinator.NodeManager` via RPC. It needs to be updated to write to Postgres via the new `Mxc.Coordinator` context instead.

**Files:**
- Modify: `lib/mxc/agent/health.ex:85-103` — change `report_to_coordinator/1`

**Step 1: Update heartbeat reporting**

The agent health reporter should call `Mxc.Coordinator.heartbeat/2` or `Mxc.Coordinator.register_node/1` on the coordinator node via RPC. Since the agent doesn't have direct DB access, it still uses Erlang distribution to call the coordinator:

Update the `report_to_coordinator/1` function in `lib/mxc/agent/health.ex`:

```elixir
defp report_to_coordinator(state) do
  status = build_status(state)

  coordinator_nodes =
    Node.list()
    |> Enum.filter(&coordinator_node?/1)

  case coordinator_nodes do
    [coordinator | _] ->
      # Register/update node via the Coordinator context on the coordinator node
      :rpc.call(coordinator, Mxc.Coordinator, :register_node, [%{
        hostname: node() |> Atom.to_string(),
        status: "available",
        cpu_total: status[:cpu_cores],
        memory_total: status[:memory_mb],
        cpu_used: status[:cpu_cores] - status[:available_cpu],
        memory_used: status[:memory_mb] - status[:available_memory_mb],
        hypervisor: if(status[:hypervisor], do: Atom.to_string(status[:hypervisor])),
        last_heartbeat_at: DateTime.utc_now()
      }])

    [] ->
      Logger.debug("No coordinator node found, skipping heartbeat")
  end
end
```

**Step 2: Run compilation check**

Run: `nix develop -c mix compile --warnings-as-errors`
Expected: Clean compilation

---

### Task 10: Integration test — end-to-end flow

Verify the complete data flow: Ecto write → PubSub → FactStore → datalox rules → derived facts.

**Files:**
- Create: `test/mxc/coordinator/integration_test.exs`

**Step 1: Write integration test**

Create `test/mxc/coordinator/integration_test.exs`:
```elixir
defmodule Mxc.Coordinator.IntegrationTest do
  use Mxc.DataCase, async: false

  alias Mxc.Coordinator
  alias Mxc.Coordinator.FactStore

  setup do
    start_supervised!(FactStore)
    # Give FactStore time to initialize
    Process.sleep(200)
    :ok
  end

  describe "end-to-end: node registration → fact projection" do
    test "registering a node creates facts in datalox" do
      {:ok, node} = Coordinator.register_node(%{
        hostname: "test-agent-e2e",
        status: "available",
        cpu_total: 8,
        memory_total: 16384,
        cpu_used: 0,
        memory_used: 0,
        last_heartbeat_at: DateTime.utc_now()
      })

      # Wait for PubSub delivery
      Process.sleep(100)

      # Verify facts exist in datalox
      results = FactStore.query({:node, node.id, :_, :_})
      assert length(results) == 1

      [{:node, id, hostname, status}] = results
      assert id == node.id
      assert hostname == "test-agent-e2e"
      assert status == :available
    end
  end

  describe "end-to-end: workload deployment" do
    test "creating a workload with no nodes returns error" do
      result = Coordinator.deploy_workload(%{
        command: "echo hello",
        cpu: 1,
        memory_mb: 256
      })

      assert {:error, :no_nodes} = result
    end
  end
end
```

**Step 2: Run integration tests**

Run: `nix develop -c mix test test/mxc/coordinator/integration_test.exs`
Expected: Tests pass

---

### Task 11: Clean up removed modules

Delete the old imperative modules that have been replaced.

**Files:**
- Delete: `lib/mxc/coordinator/scheduler.ex` (replaced by datalox rules + FactStore.select_node)
- Keep but deprecate: `lib/mxc/coordinator/node_manager.ex` (may still be needed for agent-side RPC compatibility during transition)
- Keep but deprecate: `lib/mxc/coordinator/workload.ex` (may still be needed for agent-side RPC compatibility during transition)

**Step 1: Remove Scheduler**

Delete `lib/mxc/coordinator/scheduler.ex` — its logic is now in `priv/rules/scheduling.dl` + `FactStore.select_node/2`.

**Step 2: Remove unused alias from Coordinator**

Ensure `lib/mxc/coordinator.ex` no longer aliases `Scheduler`, `NodeManager`, or the old `Workload` GenServer.

**Step 3: Run full test suite**

Run: `nix develop -c mix test`
Expected: All tests pass

Run: `nix develop -c mix compile --warnings-as-errors`
Expected: Clean compilation with no warnings

---

### Task 12: Final verification

**Step 1: Format code**

Run: `nix develop -c mix format`

**Step 2: Full quality check**

Run: `nix develop -c mix compile --warnings-as-errors`
Expected: No warnings

Run: `nix develop -c mix test`
Expected: All tests pass

**Step 3: Verify the application starts**

Run: `nix develop -c bash -c "just pg-start && mix ecto.migrate && mix phx.server"`
Expected: Server starts, dashboard loads at http://localhost:4000

**Step 4: Verify datalox is reasoning**

In IEx (`nix develop -c iex -S mix`):
```elixir
Mxc.Coordinator.FactStore.query({:now, :_})
# Should return [{:now, unix_timestamp}]
```
