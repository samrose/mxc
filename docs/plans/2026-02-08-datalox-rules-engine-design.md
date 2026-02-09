# Datalox Rules Engine Integration Design

## Summary

Replace the hardcoded imperative business logic in mxc's coordinator (scheduler, node manager, workload lifecycle) with a declarative rules engine powered by [datalox](https://github.com/samrose/datalox). PostgreSQL remains the source of truth for all persistent state via Ecto. datalox runs as an in-memory ETS-backed reasoning engine that derives scheduling decisions, health assessments, and lifecycle transitions from facts and rules.

## Motivation

Orchestration systems traditionally hardcode workflows as sequential code — imperative schedulers, polling-based health checks, manually coded state machines. This creates brittle systems where changing a scheduling policy or adding a placement constraint requires code changes and redeployment.

A rules engine inverts this: you declare facts (cluster state, resource availability, workload requirements) and rules (scheduling policies, lifecycle transitions, constraints), and the correct actions emerge from the current state of the world. When facts change, affected rules re-fire automatically. Every decision is traceable via derivation trees.

Key principles from the [Inferal blog](https://inferal.com/blog/):
- Workflows should emerge from declared conditions, not hardcoded sequences
- Rules fire concurrently without explicit coordination
- Every activation leaves a trace — the system knows why a decision was made
- Facts remain constant while rules adapt — no state migration needed
- Conditions are tested independently rather than exponential execution paths

## Architecture

### Data Flow

```
Write path:  Event -> Postgres (Ecto) -> PubSub -> FactStore -> datalox assert/retract
Read path:   Display: Ecto queries  |  Decisions: datalox queries
Startup:     Postgres -> bulk load into datalox
```

### Component Diagram

```
+------------------------------------------------------------------+
|                        Coordinator                                |
|                                                                   |
|  +-----------+     +------------+     +-----------+               |
|  |   Ecto    |---->|  FactStore |---->|  datalox  |               |
|  | (Postgres)|     | (projection|     | (ETS,     |               |
|  |           |     |  + sync)   |     |  rules)   |               |
|  +-----+-----+     +-----+------+     +-----+-----+              |
|        |                  |                  |                     |
|        |           PubSub |           derived facts               |
|        |                  |                  |                     |
|  +-----+-----+     +-----+------+     +-----+-----+              |
|  | Web UI +  |     | Reconciler |     |  Reactor  |              |
|  | REST API  |     | (30s diff) |     | (actions) |              |
|  +-----------+     +------------+     +-----+-----+              |
|                                             |                     |
+---------------------------------------------|---------------------+
                                              | RPC
                                     +--------+--------+
                                     |    Agents       |
                                     | (unchanged)     |
                                     +-----------------+
```

### Key Principle: Ecto for Display, datalox for Decisions

- LiveViews and API controllers query Ecto/Postgres for listing, pagination, sorting, filtering
- datalox is consulted only for rule-based decisions: placement, lifecycle transitions, health, alerts
- Two tools, each doing what they're good at, with a clear boundary

## PostgreSQL Schema

### nodes

| Column | Type | Description |
|--------|------|-------------|
| id | uuid | Primary key |
| hostname | text | Node hostname |
| status | text | :available, :unavailable, :draining |
| cpu_total | integer | Total CPU cores |
| memory_total | integer | Total memory MB |
| cpu_used | integer | Currently used CPU cores |
| memory_used | integer | Currently used memory MB |
| hypervisor | text | qemu, cloud-hypervisor, vfkit, or null |
| capabilities | jsonb | Additional capabilities (gpu, storage type, etc.) |
| last_heartbeat_at | utc_datetime | Last health report |
| inserted_at | utc_datetime | |
| updated_at | utc_datetime | |

### workloads

| Column | Type | Description |
|--------|------|-------------|
| id | uuid | Primary key |
| type | text | :process or :microvm |
| status | text | :pending, :starting, :running, :stopping, :stopped, :failed |
| node_id | uuid (FK) | Placed on which node (nullable) |
| command | text | Command to execute |
| args | jsonb | Command arguments |
| env | jsonb | Environment variables |
| cpu_required | integer | CPU cores needed |
| memory_required | integer | Memory MB needed |
| constraints | jsonb | Placement constraints (capabilities required) |
| error | text | Last error message |
| started_at | utc_datetime | |
| stopped_at | utc_datetime | |
| inserted_at | utc_datetime | |
| updated_at | utc_datetime | |

### workload_events

| Column | Type | Description |
|--------|------|-------------|
| id | uuid | Primary key |
| workload_id | uuid (FK) | |
| event_type | text | State transition or notable event |
| metadata | jsonb | Additional event data |
| inserted_at | utc_datetime | |

### scheduling_rules

| Column | Type | Description |
|--------|------|-------------|
| id | uuid | Primary key |
| name | text | Human-readable name |
| description | text | What this rule does |
| rule_text | text | Raw Datalog source |
| enabled | boolean | Whether to load this rule |
| priority | integer | Load order |
| inserted_at | utc_datetime | |
| updated_at | utc_datetime | |

## Fact Schema

Ecto records are projected into normalized datalox facts. Each entity maps to multiple narrow fact types optimized for rule composition.

### From nodes table

```
node(NodeId, Hostname, Status)
node_resources(NodeId, CpuTotal, MemTotal)
node_resources_used(NodeId, CpuUsed, MemUsed)
node_capability(NodeId, CapType, CapValue)
node_heartbeat(NodeId, LastSeenUnix)
```

### From workloads table

```
workload(WorkloadId, Type, Status)
workload_placement(WorkloadId, NodeId)
workload_resources(WorkloadId, CpuReq, MemReq)
workload_constraint(WorkloadId, CapType, CapValue)
```

### From workload_events table

```
workload_event(WorkloadId, EventType, Timestamp)
```

### System facts

```
now(UnixTimestamp)    % updated every 5 seconds
```

## Shipped Rules

### priv/rules/scheduling.dl

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

Strategy selection (spread/pack/random) is handled in Elixir by querying `placement_candidate` and sorting:

```elixir
def select_node(workload_id, strategy) do
  candidates = Datalox.query(db, {:placement_candidate, workload_id, :_, :_, :_})

  case {candidates, strategy} do
    {[], _}          -> {:error, :no_available_nodes}
    {list, :spread}  -> {:ok, Enum.max_by(list, &resource_score/1)}
    {list, :pack}    -> {:ok, Enum.min_by(list, &resource_score/1)}
    {list, :random}  -> {:ok, Enum.random(list)}
  end
end
```

### priv/rules/lifecycle.dl

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

% A workload is restartable if it failed and its original constraints are still satisfiable
can_restart(Workload) :-
    workload(Workload, _, :failed),
    can_place(Workload, _).
```

### priv/rules/health.dl

```datalog
% Node is stale if heartbeat older than 30s but not yet marked unavailable
node_stale(Node) :-
    node(Node, _, :available),
    node_heartbeat(Node, LastSeen),
    now(Now),
    Now - LastSeen >= 30.

% Node is overloaded if resource usage exceeds 90%
node_overloaded(Node) :-
    node_resources(Node, CpuTotal, _),
    node_resources_used(Node, CpuUsed, _),
    CpuUsed * 100 / CpuTotal > 90.

node_overloaded(Node) :-
    node_resources(Node, _, MemTotal),
    node_resources_used(Node, _, MemUsed),
    MemUsed * 100 / MemTotal > 90.

% Cluster is degraded if fewer than 2 healthy nodes
cluster_degraded() :-
    count(Node, node_healthy(Node), N),
    N < 2.

% Workload is orphaned if placed on a node that no longer exists
workload_orphaned(Workload) :-
    workload(Workload, _, :running),
    workload_placement(Workload, Node),
    not node(Node, _, _).
```

## User-Defined Rules

Operators create custom rules via the API/UI. User rules extend the `constraint_violated` predicate — the same predicate shipped scheduling rules already check. Operators don't need to understand the scheduling engine; they just declare new reasons a placement would be invalid.

Examples:

```datalog
% Anti-affinity: don't co-locate workloads with the same group tag
constraint_violated(Workload, Node) :-
    workload_constraint(Workload, :group, Group),
    workload_placement(Other, Node),
    workload_constraint(Other, :group, Group),
    Other != Workload.

% Capacity limit: no more than 5 workloads per node
constraint_violated(Workload, Node) :-
    count(W, workload_placement(W, Node), N),
    N >= 5.
```

Rules are validated by datalox's safety checker before being accepted. Malformed or unsafe rules are rejected with an error.

## New Components

### Mxc.Coordinator.FactStore (GenServer)

Manages the datalox database instance. Responsibilities:
- Creates datalox database on init (ETS-backed)
- Loads shipped rules from `priv/rules/*.dl` on startup
- Loads enabled user rules from `scheduling_rules` table on startup
- Queries all domain tables and bulk-asserts projected facts on startup
- Subscribes to PubSub for real-time fact sync on Ecto writes
- Updates `now(Timestamp)` fact every 5 seconds
- Runs diff-based reconciliation every 30 seconds
- Reloads user rules when `scheduling_rules` table changes
- Exposes query API for Reactor and Coordinator context

### Mxc.Coordinator.Reactor (GenServer)

Subscribes to datalox derived facts and executes side effects:

| Derived Fact | Action |
|--------------|--------|
| `node_stale(NodeId)` | Set node status to :unavailable in Postgres |
| `should_fail(WorkloadId)` | RPC agent to stop, set workload status to :failed |
| `workload_orphaned(WorkloadId)` | Set workload status to :failed, clear placement |
| `can_restart(WorkloadId)` | Run select_node, start on best available node |
| `cluster_degraded()` | Log warning, notify admin |

The Reactor is idempotent — duplicate derivations are safe (stopping an already-stopped workload is a no-op).

### Mxc.Coordinator.FactProjection (pure functions)

Maps Ecto structs to fact tuples:

```elixir
def project(%Node{} = node) do
  [
    {:node, node.id, node.hostname, String.to_atom(node.status)},
    {:node_resources, node.id, node.cpu_total, node.memory_total},
    {:node_resources_used, node.id, node.cpu_used, node.memory_used},
    {:node_heartbeat, node.id, DateTime.to_unix(node.last_heartbeat_at)}
  ] ++ capability_facts(node)
end

def project(%Workload{} = wl) do
  [
    {:workload, wl.id, String.to_atom(wl.type), String.to_atom(wl.status)},
    {:workload_resources, wl.id, wl.cpu_required, wl.memory_required}
  ]
  |> maybe_add({:workload_placement, wl.id, wl.node_id}, wl.node_id)
  ++ constraint_facts(wl)
end
```

## Sync Mechanism

### Real-time: PubSub on Ecto writes

Every Ecto insert/update/delete broadcasts via Phoenix.PubSub:

```elixir
Phoenix.PubSub.broadcast(Mxc.PubSub, "fact_changes", {:fact_change, :nodes, :update, node})
```

FactStore subscribes, projects the changed record to facts, and asserts/retracts in datalox.

### Periodic: Diff-based reconciliation (every 30 seconds)

FactStore queries all rows from Postgres, projects them to facts, and diffs against current datalox state. Only asserts missing facts and retracts stale ones. Typically a no-op when PubSub is working correctly. Self-healing when it's not.

The diff approach avoids disrupting datalox — existing facts remain valid throughout reconciliation. No retract-all/assert-all window.

### Time: Tick every 5 seconds

FactStore retracts old `now(_)` and asserts new `now(UnixTimestamp)`. Time-dependent rules (node_healthy, node_stale) re-evaluate.

## Startup Sequence

```
1. Ecto connects to Postgres, runs migrations
2. Coordinator.Supervisor starts
3. FactStore GenServer starts:
   a. Creates datalox database (ETS-backed)
   b. Loads shipped rules from priv/rules/*.dl
   c. Loads enabled user rules from scheduling_rules table
   d. Queries all nodes, workloads, events from Postgres
   e. Projects each row into normalized facts, bulk assert_all
   f. Asserts now(UnixTimestamp) fact
4. Reactor starts, subscribes to derived facts
5. Web endpoint starts
6. Cluster topology starts (libcluster)
```

## Impact on Existing Code

### Unchanged
- `Mxc.Agent.*` — executor, health, vm_manager (agents don't know about datalox)
- `Mxc.CLI.*` — talks to REST API
- `MxcWeb.*` LiveViews and API controllers — query Ecto for display
- `Mxc.Coordinator.Cluster` — libcluster topology config
- All Nix infrastructure

### Replaced
- `Mxc.Coordinator.Scheduler` — replaced by datalox scheduling rules + select_node/2
- `Mxc.Coordinator.Workload` GenServer — workload state moves to Postgres, lifecycle logic to rules + Reactor
- `Mxc.Coordinator.NodeManager` GenServer — node state moves to Postgres, health logic to rules

### New
- `Mxc.Coordinator.FactStore` GenServer
- `Mxc.Coordinator.Reactor` GenServer
- `Mxc.Coordinator.FactProjection` module
- Ecto schemas: Node, Workload, WorkloadEvent, SchedulingRule
- 4 database migrations
- `priv/rules/scheduling.dl`, `lifecycle.dl`, `health.dl`

### Modified
- `Mxc.Coordinator.Supervisor` — starts FactStore and Reactor
- `Mxc.Coordinator` context — delegates to Ecto for CRUD, to FactStore for rule queries
- API controllers — write to Ecto instead of calling GenServers

## Dependencies

Add to `mix.exs`:

```elixir
{:datalox, "~> 0.1.0"}
```

datalox requires Elixir >= 1.18. The current project specifies `~> 1.15` — this will need to be bumped.
