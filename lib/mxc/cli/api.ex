defmodule Mxc.CLI.API do
  @moduledoc """
  HTTP client for communicating with the coordinator API.
  """

  @doc """
  Performs a GET request to the coordinator.
  """
  def get(coordinator, path) do
    url = "#{coordinator}#{path}"

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, %{reason: reason}} ->
        {:error, reason}
    end
  end

  @doc """
  Performs a POST request to the coordinator.
  """
  def post(coordinator, path, body) do
    url = "#{coordinator}#{path}"

    case Req.post(url, json: body) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, %{reason: reason}} ->
        {:error, reason}
    end
  end

  @doc """
  Performs a DELETE request to the coordinator.
  """
  def delete(coordinator, path) do
    url = "#{coordinator}#{path}"

    case Req.delete(url) do
      {:ok, %{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, %{reason: reason}} ->
        {:error, reason}
    end
  end
end
