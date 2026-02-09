defmodule MxcWeb.Plugs.APIAuth do
  @moduledoc """
  Bearer token authentication for the API.

  Checks the `Authorization: Bearer <token>` header against the configured
  `MXC_API_TOKEN`. Returns 401 if missing or invalid.

  Configure via:
    config :mxc, :api_token, "your-secret-token"

  Or at runtime via the MXC_API_TOKEN environment variable.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:mxc, :api_token) do
      nil ->
        # No token configured — auth disabled (dangerous, but explicit)
        conn

      configured_token ->
        with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
             true <- Plug.Crypto.secure_compare(token, configured_token) do
          conn
        else
          _ ->
            conn
            |> put_status(:unauthorized)
            |> Phoenix.Controller.json(%{error: "Invalid or missing API token"})
            |> halt()
        end
    end
  end
end
