defmodule MangoCMSWeb.PageController do
  use MangoCMSWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
