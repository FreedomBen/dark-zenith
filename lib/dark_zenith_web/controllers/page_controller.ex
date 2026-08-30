defmodule DarkZenithWeb.PageController do
  use DarkZenithWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
