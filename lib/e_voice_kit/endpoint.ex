defmodule EVoiceKit.Endpoint do
  @moduledoc """
  HTTP and WebSocket router for incoming carrier webhooks and media streams.

  Powered by Plug and Bandit.
  """

  use Plug.Router
  require Logger

  plug(CORSPlug, origin: ["*"])
  plug(:match)

  # Support both JSON and URL-encoded form data (required for Twilio webhooks)
  plug(Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:dispatch)

  # Health Check Endpoint
  get "/health" do
    active_calls = EVoiceKit.active_calls_count()

    response = %{
      "status" => "healthy",
      "active_calls" => active_calls,
      "timestamp" => System.system_time(:second)
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  # Inbound Twilio Media Stream WebSocket
  # Timeout set to :infinity so telephony calls are not dropped during holds or long silences
  get "/media/twilio" do
    conn
    |> WebSockAdapter.upgrade(EVoiceKit.Transports.TwilioWebSocket, [], timeout: :infinity)
    |> halt()
  end

  # Inbound Telnyx Media Stream WebSocket
  get "/media/telnyx" do
    conn
    |> WebSockAdapter.upgrade(EVoiceKit.Transports.TelnyxWebSocket, [], timeout: :infinity)
    |> halt()
  end

  # Inbound Vonage Media Stream WebSocket
  get "/media/vonage" do
    conn
    |> WebSockAdapter.upgrade(EVoiceKit.Transports.VonageWebSocket, [], timeout: :infinity)
    |> halt()
  end

  # Webhook to return TwiML for Twilio inbound phone calls
  post "/twiml" do
    host = conn.host
    proto = if conn.scheme == :https, do: "wss", else: "ws"
    stream_url = "#{proto}://#{host}:#{conn.port}/media/twilio"

    to_number = conn.params["To"] || ""
    from_number = conn.params["From"] || ""
    tenant_id = conn.params["tenant_id"] || ""
    assistant_id = conn.params["assistant_id"] || ""

    stream_params =
      [
        {"caller_number", from_number},
        {"dialed_number", to_number},
        {"tenant_id", tenant_id},
        {"assistant_id", assistant_id}
      ]
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Enum.map(fn {k, v} -> ~s(      <Parameter name="#{k}" value="#{v}" />\n) end)
      |> Enum.join()

    twiml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Response>
      <Connect>
        <Stream url="#{stream_url}">
    #{stream_params}    </Stream>
      </Connect>
    </Response>
    """

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, twiml)
  end

  # Dynamic Call Reconfiguration Endpoint
  post "/calls/:call_id/reconfigure" do
    case EVoiceKit.reconfigure_call(call_id, conn.body_params) do
      :ok ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"status" => "reconfigured", "call_id" => call_id}))

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "call_not_found"}))

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{"error" => to_string(reason)}))
    end
  end

  # Twilio Call Status Callback Webhook
  post "/webhooks/twilio/status" do
    call_sid = conn.params["CallSid"] || ""
    call_status = conn.params["CallStatus"] || ""
    duration = conn.params["CallDuration"] || conn.params["Duration"]

    Logger.info("[Twilio:Webhook] Call #{call_sid} status: #{call_status}, duration: #{duration}s")
    canonical_status = EVoiceKit.Providers.Events.normalize_webhook_status(conn.params)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"received" => true, "status" => to_string(canonical_status)}))
  end

  # Twilio Call Recording Callback Webhook
  post "/webhooks/twilio/recording" do
    call_sid = conn.params["CallSid"] || ""
    recording_url = conn.params["RecordingUrl"] || ""
    duration = conn.params["RecordingDuration"] || ""

    Logger.info("[Twilio:Webhook] Call #{call_sid} recording ready: #{recording_url} (#{duration}s)")

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"received" => true, "recording_url" => recording_url}))
  end

  # Telnyx Call Control Webhook
  post "/webhooks/telnyx/events" do
    data = conn.body_params["data"] || conn.params
    event_type = get_in(data, ["event_type"]) || conn.params["event_type"]
    call_id = get_in(data, ["payload", "call_control_id"]) || conn.params["call_control_id"]

    Logger.info("[Telnyx:Webhook] Event: #{event_type}, CallControlId: #{call_id}")
    canonical_status = EVoiceKit.Providers.Events.normalize_webhook_status(%{"event_type" => event_type})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"received" => true, "canonical_event" => to_string(canonical_status)}))
  end

  # Vonage Voice Webhook
  post "/webhooks/vonage/events" do
    uuid = conn.params["uuid"] || ""
    status = conn.params["status"] || ""

    Logger.info("[Vonage:Webhook] Call #{uuid} status: #{status}")
    canonical_status = EVoiceKit.Providers.Events.normalize_webhook_status(conn.params)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"received" => true, "status" => to_string(canonical_status)}))
  end

  # Fallback 404
  # Native WebRTC SFU Signaling WebSocket Endpoint
  get "/rtc/v1" do
    token = conn.query_params["token"]

    conn
    |> WebSockAdapter.upgrade(EVoiceKit.Signaling.WebSocket, [token: token], timeout: :infinity)
    |> halt()
  end

  # Token issuance is a backend-only operation. The issuer key must never be shipped
  # to browser/mobile clients; end users receive short-lived tokens from their backend.
  post "/rtc/v1/token" do
    configured_issuer_key = System.get_env("EVK_TOKEN_ISSUER_KEY")
    [provided_issuer_key] = Plug.Conn.get_req_header(conn, "x-evk-issuer-key") ++ [nil]

    authorized =
      is_binary(configured_issuer_key) and byte_size(configured_issuer_key) >= 32 and
        is_binary(provided_issuer_key) and
        Plug.Crypto.secure_compare(configured_issuer_key, provided_issuer_key)

    params = conn.body_params
    tenant_id = params["tenant_id"]
    room = params["room"]
    identity = params["identity"]
    permissions = params["permissions"]
    ttl = params["ttl"] || 3600

    valid_request =
      Enum.all?([tenant_id, room, identity], &(is_binary(&1) and byte_size(&1) in 1..256)) and
        is_map(permissions) and
        Enum.all?(["can_publish", "can_subscribe", "can_publish_data"], fn key ->
          is_boolean(Map.get(permissions, key))
        end) and is_integer(ttl) and ttl in 1..3600

    cond do
      not authorized ->
        conn |> put_resp_content_type("application/json") |> send_resp(401, Jason.encode!(%{"error" => "issuer_unauthorized"}))

      not valid_request ->
        conn |> put_resp_content_type("application/json") |> send_resp(400, Jason.encode!(%{"error" => "invalid_token_request"}))

      true ->
        claims = %{
          "tenant_id" => tenant_id,
          "room" => room,
          "identity" => identity,
          "permissions" => permissions
        }

        case EVoiceKit.Auth.Token.generate(claims, ttl: ttl) do
          {:ok, token} ->
            response = %{
              "token" => token,
              "tenant_id" => tenant_id,
              "room" => room,
              "identity" => identity,
              "permissions" => permissions,
              "ws_url" => "/rtc/v1?token=" <> URI.encode_www_form(token),
              "expires_in" => ttl
            }

            conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(response))

          {:error, reason} ->
            Logger.error("Token issuance failed: #{inspect(reason)}")
            conn |> put_resp_content_type("application/json") |> send_resp(503, Jason.encode!(%{"error" => "token_issuer_unavailable"}))
        end
    end
  end

  # Fallback 404
  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
