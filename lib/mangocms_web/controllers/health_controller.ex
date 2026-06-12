defmodule MangoCMSWeb.HealthController do
  @moduledoc """
  Health check endpoint used by the Docker HEALTHCHECK and the
  post-deploy smoke test in the Jenkins pipeline.

  Returns 200 with database connectivity status. The endpoint itself
  responding proves the VM, endpoint, and router are alive; the `db`
  field reports whether the repo can reach PostgreSQL.
  """
  use MangoCMSWeb, :controller

  alias Ecto.Adapters.SQL
  alias MangoCMS.Repo

  def show(conn, _params) do
    json(conn, %{status: "ok", db: db_status()})
  end

  defp db_status do
    case SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} -> "ok"
      {:error, _} -> "unavailable"
    end
  rescue
    _ -> "unavailable"
  end
end
