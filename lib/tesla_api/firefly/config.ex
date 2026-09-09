defmodule TeslaApi.Firefly.Config do
  @moduledoc """
  Helper module for Firefly API configuration.
  Parses `FIREFLY_CURL` or `FIREFLY_API_URL` and `FIREFLY_API_HEADERS`.
  """

  @doc """
  Returns `{url, headers}` tuple by inspecting environment variables:
  `FIREFLY_CURL`, `FIREFLY_API_URL`, `FIREFLY_API_HEADERS`.
  """
  def get_config do
    curl_str = System.get_env("FIREFLY_CURL")
    url_env = System.get_env("FIREFLY_API_URL")
    headers_env = System.get_env("FIREFLY_API_HEADERS")

    {curl_url, curl_headers} =
      if curl_str && String.trim(curl_str) != "" do
        parse_curl(curl_str)
      else
        {nil, []}
      end

    url =
      cond do
        url_env && String.trim(url_env) != "" -> String.trim(url_env)
        curl_url -> curl_url
        true -> "http://localhost:8080/grill-me"
      end

    headers =
      if headers_env && String.trim(headers_env) != "" do
        parse_headers_string(headers_env)
      else
        curl_headers
      end

    {url, headers}
  end

  @doc """
  Parses a curl command string into `{url, headers_list}`.
  Supports quotes, `-H` or `--header`, and single/double quoted URLs/Headers.
  """
  def parse_curl(curl_cmd) when is_binary(curl_cmd) do
    tokens = tokenize_command(curl_cmd)

    url = find_url(tokens)
    headers = find_headers(tokens)

    {url, headers}
  end

  def parse_curl(_), do: {nil, []}

  @doc """
  Parses a headers string like "Header1: Value1\nHeader2: Value2" or "Header1: Value1; Header2: Value2"
  """
  def parse_headers_string(str) when is_binary(str) do
    str
    |> String.split(~r/(\r?\n|;)/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [k, v] -> [{String.trim(k), String.trim(v)}]
        _ -> []
      end
    end)
  end

  def parse_headers_string(_), do: []

  # Private helpers

  defp tokenize_command(cmd) do
    # Simple lexer for command arguments handling single/double quotes and backslash escaping
    Regex.scan(~r/'[^']*'|"[^"]*"|\S+/, cmd)
    |> List.flatten()
    |> Enum.map(fn token ->
      case token do
        "'" <> rest -> String.slice(rest, 0, String.length(rest) - 1)
        "\"" <> rest -> String.slice(rest, 0, String.length(rest) - 1)
        other -> other
      end
    end)
  end

  defp find_url(tokens) do
    # Ignore "curl" and flag arguments with their values
    skip_next? = fn token ->
      token in [
        "-H", "--header",
        "-X", "--request",
        "-d", "--data", "--data-raw", "--data-binary",
        "-A", "--user-agent",
        "-u", "--user",
        "-b", "--cookie",
        "-c", "--cookie-jar",
        "-e", "--referer",
        "-m", "--max-time",
        "-o", "--output"
      ]
    end

    extract_url(tokens, skip_next?)
  end

  defp extract_url([], _skip_fn), do: nil

  defp extract_url(["curl" | rest], skip_fn), do: extract_url(rest, skip_fn)

  defp extract_url([token, _val | rest], skip_fn) do
    if skip_fn.(token) do
      extract_url(rest, skip_fn)
    else
      check_url_token(token, [token, _val | rest], skip_fn)
    end
  end

  defp extract_url([token | rest], skip_fn) do
    check_url_token(token, [token | rest], skip_fn)
  end

  defp check_url_token(token, list, skip_fn) do
    if String.starts_with?(token, "-") do
      [_head | tail] = list
      extract_url(tail, skip_fn)
    else
      if String.starts_with?(token, "http://") or String.starts_with?(token, "https://") do
        token
      else
        # Try next token if it didn't look like an http(s) URL but isn't a flag
        [_head | tail] = list
        extract_url(tail, skip_fn) || token
      end
    end
  end

  defp find_headers(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [flag, _val] -> flag in ["-H", "--header"] end)
    |> Enum.flat_map(fn [_flag, val] ->
      case String.split(val, ":", parts: 2) do
        [k, v] -> [{String.trim(k), String.trim(v)}]
        _ -> []
      end
    end)
  end
end
