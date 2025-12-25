defmodule MxcWeb.PageController do
  use MxcWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
