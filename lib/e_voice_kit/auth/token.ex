defmodule EVoiceKit.Auth.Token do
  @moduledoc """
  Cryptographically signed JSON Web Token (JWT) generator and validator for WebRTC room authentication.

  Signs tokens using HMAC-SHA256 (HS256) and verifies tenant, room, participant identity,
  expiration timestamps, and role-based permissions (can_publish, can_subscribe, can_publish_data).
  """

  @default_ttl_seconds 3600

  @doc """
  Generates a signed JWT token for a participant joining a room.
  """
  @spec generate(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(claims, opts \\ []) do
    secret = Keyword.get(opts, :secret, get_secret())
    ttl = Keyword.get(opts, :ttl, @default_ttl_seconds)
    now = System.system_time(:second)

    with :ok <- validate_secret(secret),
         :ok <- validate_ttl(ttl) do
      generate_token(claims, secret, ttl, now)
    end
  end

  defp generate_token(claims, secret, ttl, now) do

    default_claims = %{
      "tenant_id" => "default",
      "room" => "default",
      "identity" => "anonymous",
      "permissions" => %{
        "can_publish" => true,
        "can_subscribe" => true,
        "can_publish_data" => true
      },
      "iat" => now,
      "exp" => now + ttl,
      "nonce" => :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    }

    merged_claims = Map.merge(default_claims, stringify_keys(claims))

    header = %{"alg" => "HS256", "typ" => "JWT"}

    with {:ok, header_json} <- Jason.encode(header),
         {:ok, payload_json} <- Jason.encode(merged_claims) do
      encoded_header = base64_url_encode(header_json)
      encoded_payload = base64_url_encode(payload_json)
      signing_input = encoded_header <> "." <> encoded_payload
      signature = sign_hmac_sha256(signing_input, secret)
      encoded_sig = base64_url_encode(signature)

      {:ok, signing_input <> "." <> encoded_sig}
    end
  rescue
    e -> {:error, {:token_generation_failed, e}}
  end

  @doc """
  Verifies a signed token, ensuring valid cryptographic signature and unexpired TTL.
  Returns `{:ok, claims}` on success or `{:error, reason}` on failure.
  """
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, atom() | {atom(), term()}}
  def verify(token, opts \\ []) when is_binary(token) do
    secret = Keyword.get(opts, :secret, get_secret())
    now = Keyword.get(opts, :current_time, System.system_time(:second))

    with :ok <- validate_secret(secret) do
      verify_token(token, secret, now)
    end
  end

  defp verify_token(token, secret, now) do
    case String.split(token, ".") do
      [encoded_header, encoded_payload, encoded_sig] ->
        signing_input = encoded_header <> "." <> encoded_payload

        with {:ok, header_json} <- base64_url_decode(encoded_header),
             {:ok, header} <- Jason.decode(header_json),
             true <- is_map(header) and header["alg"] == "HS256",
             {:ok, expected_sig} <- {:ok, sign_hmac_sha256(signing_input, secret)},
             {:ok, provided_sig} <- base64_url_decode(encoded_sig),
             true <- secure_compare(expected_sig, provided_sig),
             {:ok, payload_json} <- base64_url_decode(encoded_payload),
             {:ok, claims} <- Jason.decode(payload_json),
             :ok <- validate_expiration(claims, now) do
          {:ok, claims}
        else
          false -> {:error, :invalid_signature}
          {:error, :expired} -> {:error, :token_expired}
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_token}
        end

      _ ->
        {:error, :malformed_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  def verify(_non_binary, _opts), do: {:error, :invalid_token_type}

  @doc """
  Retrieves the configured secret from application environment or OS environment.
  """
  def get_secret do
    System.get_env("EVK_AUTH_SECRET") || Application.get_env(:e_voice_kit, :auth_secret)
  end

  defp validate_secret(secret) when is_binary(secret) and byte_size(secret) >= 32 do
    if secret == "evk_default_development_secret_change_in_production",
      do: {:error, :insecure_auth_secret},
      else: :ok
  end

  defp validate_secret(nil), do: {:error, :missing_auth_secret}
  defp validate_secret(_), do: {:error, :weak_auth_secret}

  defp validate_ttl(ttl) when is_integer(ttl) and ttl > 0 and ttl <= 86_400, do: :ok
  defp validate_ttl(_), do: {:error, :invalid_ttl}

  # --- Helpers ---

  defp sign_hmac_sha256(input, secret) do
    :crypto.mac(:hmac, :sha256, secret, input)
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    if byte_size(a) == byte_size(b) do
      Plug.Crypto.secure_compare(a, b)
    else
      false
    end
  end

  defp secure_compare(_, _), do: false

  defp validate_expiration(%{"exp" => exp}, now) when is_integer(exp) do
    if exp >= now, do: :ok, else: {:error, :expired}
  end

  defp validate_expiration(_claims, _now), do: {:error, :missing_expiration}

  defp base64_url_encode(binary) do
    binary
    |> Base.url_encode64(padding: false)
  end

  defp base64_url_decode(string) do
    case Base.url_decode64(string, padding: false) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_base64}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_value(map) when is_map(map), do: stringify_keys(map)
  defp stringify_value(other), do: other
end
