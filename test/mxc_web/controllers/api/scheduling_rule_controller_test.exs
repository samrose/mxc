defmodule MxcWeb.API.SchedulingRuleControllerTest do
  use MxcWeb.ConnCase, async: true

  alias Mxc.Coordinator

  setup do
    {:ok, rule} =
      Coordinator.create_scheduling_rule(%{
        name: "test-rule",
        description: "A test scheduling rule",
        rule_text: "candidate(W, N) :- workload(W, _, pending), node(N, _, available).",
        enabled: true,
        priority: 10
      })

    %{rule: rule}
  end

  describe "GET /api/rules" do
    test "returns list of rules", %{conn: conn, rule: rule} do
      conn = conn |> authed() |> get(~p"/api/rules")
      assert %{"data" => rules} = json_response(conn, 200)
      assert length(rules) == 1
      assert hd(rules)["name"] == rule.name
    end

    test "returns empty list when no rules", %{conn: conn, rule: rule} do
      Coordinator.delete_scheduling_rule(rule)
      conn = conn |> authed() |> get(~p"/api/rules")
      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "GET /api/rules/:id" do
    test "returns a rule by id", %{conn: conn, rule: rule} do
      conn = conn |> authed() |> get(~p"/api/rules/#{rule.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == rule.id
      assert data["name"] == "test-rule"
      assert data["rule_text"] =~ "candidate"
      assert data["priority"] == 10
    end

    test "returns 404 for missing rule", %{conn: conn} do
      conn = conn |> authed() |> get(~p"/api/rules/#{Ecto.UUID.generate()}")
      assert %{"error" => "Scheduling rule not found"} = json_response(conn, 404)
    end
  end

  describe "POST /api/rules" do
    test "creates a rule", %{conn: conn} do
      params = %{
        "name" => "new-rule",
        "rule_text" => "foo(X) :- bar(X).",
        "priority" => 5
      }

      conn = conn |> authed() |> post(~p"/api/rules", params)
      assert %{"data" => data} = json_response(conn, 201)
      assert data["name"] == "new-rule"
      assert data["rule_text"] == "foo(X) :- bar(X)."
      assert data["priority"] == 5
      assert data["enabled"] == true
    end

    test "returns error for missing name", %{conn: conn} do
      conn = conn |> authed() |> post(~p"/api/rules", %{"rule_text" => "foo(X) :- bar(X)."})
      assert %{"error" => errors} = json_response(conn, 422)
      assert errors["name"]
    end

    test "returns error for missing rule_text", %{conn: conn} do
      conn = conn |> authed() |> post(~p"/api/rules", %{"name" => "no-text"})
      assert %{"error" => errors} = json_response(conn, 422)
      assert errors["rule_text"]
    end

    test "returns error for duplicate name", %{conn: conn} do
      params = %{"name" => "test-rule", "rule_text" => "dup(X) :- bar(X)."}
      conn = conn |> authed() |> post(~p"/api/rules", params)
      assert %{"error" => errors} = json_response(conn, 422)
      assert errors["name"]
    end
  end

  describe "PUT /api/rules/:id" do
    test "updates a rule", %{conn: conn, rule: rule} do
      conn =
        conn
        |> authed()
        |> put(~p"/api/rules/#{rule.id}", %{"priority" => 20, "enabled" => false})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["priority"] == 20
      assert data["enabled"] == false
      assert data["name"] == "test-rule"
    end

    test "returns 404 for missing rule", %{conn: conn} do
      conn = conn |> authed() |> put(~p"/api/rules/#{Ecto.UUID.generate()}", %{"priority" => 1})
      assert %{"error" => "Scheduling rule not found"} = json_response(conn, 404)
    end
  end

  describe "DELETE /api/rules/:id" do
    test "deletes a rule", %{conn: conn, rule: rule} do
      conn = conn |> authed() |> delete(~p"/api/rules/#{rule.id}")
      assert response(conn, 204)

      conn = build_conn() |> authed() |> get(~p"/api/rules/#{rule.id}")
      assert json_response(conn, 404)
    end

    test "returns 404 for missing rule", %{conn: conn} do
      conn = conn |> authed() |> delete(~p"/api/rules/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end
end
