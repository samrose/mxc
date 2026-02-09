defmodule MxcWeb.Plugs.APIAuthTest do
  use MxcWeb.ConnCase, async: true

  describe "API authentication" do
    test "rejects request with no auth header", %{conn: conn} do
      conn = get(conn, ~p"/api/cluster/status")
      assert %{"error" => "Invalid or missing API token"} = json_response(conn, 401)
    end

    test "rejects request with wrong token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> get(~p"/api/cluster/status")

      assert %{"error" => "Invalid or missing API token"} = json_response(conn, 401)
    end

    test "rejects request with malformed auth header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> get(~p"/api/cluster/status")

      assert %{"error" => "Invalid or missing API token"} = json_response(conn, 401)
    end

    test "allows request with valid token", %{conn: conn} do
      conn =
        conn
        |> authed()
        |> get(~p"/api/cluster/status")

      assert %{"data" => _} = json_response(conn, 200)
    end
  end
end
