defmodule EVoiceKit.Transports.SIP.Message do
  @moduledoc """
  High-performance binary pattern matching parser and serializer for SIP messages (RFC 3261).
  """

  defstruct method: nil,
            uri: nil,
            status_code: nil,
            reason_phrase: nil,
            headers: %{},
            body: ""

  @doc """
  Parses a raw UDP SIP text packet into a `%Message{}` struct.
  """
  def parse(packet) when is_binary(packet) do
    # Split headers from SDP body
    [header_part, body] =
      case :binary.split(packet, "\r\n\r\n") do
        [h, b] -> [h, b]
        [h] ->
          case :binary.split(packet, "\n\n") do
            [h2, b2] -> [h2, b2]
            [h2] -> [h2, ""]
          end
      end

    lines = String.split(header_part, ~r/\r?\n/)
    [start_line | header_lines] = lines

    headers = parse_headers(header_lines)

    if String.starts_with?(start_line, "SIP/2.0 ") do
      # Response: "SIP/2.0 200 OK"
      case String.split(start_line, " ", parts: 3) do
        ["SIP/2.0", code_str, reason] ->
          %__MODULE__{
            status_code: String.to_integer(code_str),
            reason_phrase: reason,
            headers: headers,
            body: body
          }

        _ ->
          {:error, :malformed_sip_response}
      end
    else
      # Request: "INVITE sip:+14155550199@gw.carrier.com SIP/2.0"
      case String.split(start_line, " ", parts: 3) do
        [method, uri, _proto] ->
          %__MODULE__{
            method: String.upcase(method),
            uri: uri,
            headers: headers,
            body: body
          }

        _ ->
          {:error, :malformed_sip_request}
      end
    end
  end

  @doc """
  Builds a SIP response string from status code, reason, headers, and optional body.
  """
  def build_response(status_code, reason_phrase, headers, body \\ "") do
    content_length = byte_size(body)
    headers = Map.put(headers, "Content-Length", to_string(content_length))

    header_lines =
      Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end)
      |> Enum.join("")

    "SIP/2.0 #{status_code} #{reason_phrase}\r\n#{header_lines}\r\n#{body}"
  end

  @doc """
  Extracts RTP IP and port from an SDP body.
  """
  def parse_sdp_audio(body) when is_binary(body) do
    # Looking for:
    # c=IN IP4 192.168.1.100
    # m=audio 10000 RTP/AVP 0 8
    ip =
      case Regex.run(~r/c=IN IP4 ([0-9.]+)/i, body) do
        [_, match_ip] -> match_ip
        _ -> nil
      end

    port =
      case Regex.run(~r/m=audio ([0-9]+)/i, body) do
        [_, match_port] -> String.to_integer(match_port)
        _ -> nil
      end

    if ip && port do
      {:ok, ip, port}
    else
      {:error, :sdp_audio_not_found}
    end
  end

  # Helper to parse and normalize headers (including compact headers)
  defp parse_headers(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, val] ->
          normalized_key = normalize_header_name(String.trim(key))
          Map.put(acc, normalized_key, String.trim(val))

        _ ->
          acc
      end
    end)
  end

  defp normalize_header_name(name) do
    case String.downcase(name) do
      "v" -> "Via"
      "f" -> "From"
      "t" -> "To"
      "i" -> "Call-ID"
      "m" -> "Contact"
      "l" -> "Content-Length"
      "c" -> "Content-Type"
      _ ->
        name
        |> String.split("-")
        |> Enum.map(&String.capitalize/1)
        |> Enum.join("-")
    end
  end
end
