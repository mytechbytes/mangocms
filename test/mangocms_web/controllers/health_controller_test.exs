defmodule MangoCMSWeb.HealthControllerTest do
  use MangoCMSWeb.ConnCase, async: true

  test "GET /health returns 200 with ok status", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert %{"status" => "ok", "db" => "ok"} = json_response(conn, 200)
  end
end
