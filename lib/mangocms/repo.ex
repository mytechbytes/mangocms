defmodule MangoCMS.Repo do
  use Ecto.Repo,
    otp_app: :mangocms,
    adapter: Ecto.Adapters.Postgres
end
