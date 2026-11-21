defmodule EVoiceKit.Compression.Negotiation do
  @moduledoc """
  Directional compression capability negotiation state machine.

  Negotiates compression separately for each direction:
  - Client-to-Server: `client_encoders ∩ server_decoders`
  - Server-to-Client: `server_encoders ∩ client_decoders`

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 9) and `docs/adr/0002-compression-binary-envelope-and-negotiation.md`.
  """

  alias EVoiceKit.Compression.Codecs.{Gzip, None}

  # Server priority order for algorithm selection
  @default_server_priority [:zstd, :brotli, :gzip, :none]

  defstruct [
    :client_to_server,
    :server_to_client,
    :chosen_c2s_algorithm,
    :chosen_s2c_algorithm,
    :negotiation_id,
    :protocol_version,
    state: :await_hello,
    client_encoders: [],
    client_decoders: [],
    server_encoders: [],
    server_decoders: []
  ]

  @type state :: :await_hello | :hello_negotiated | :active | :failed
  @type algorithm :: :none | :gzip | :brotli | :zstd
  @type t :: %__MODULE__{
          state: state(),
          client_to_server: algorithm() | nil,
          server_to_client: algorithm() | nil,
          chosen_c2s_algorithm: algorithm() | nil,
          chosen_s2c_algorithm: algorithm() | nil,
          negotiation_id: binary() | nil,
          protocol_version: integer() | binary() | nil,
          client_encoders: [algorithm()],
          client_decoders: [algorithm()],
          server_encoders: [algorithm()],
          server_decoders: [algorithm()]
        }

  @doc """
  Initializes a new negotiation context with the server's currently available codecs.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    available_codecs = available_server_codecs()
    server_priority = Keyword.get(opts, :priority, @default_server_priority)
    active_codecs = Enum.filter(server_priority, &(&1 in available_codecs))

    %__MODULE__{
      state: :await_hello,
      server_encoders: active_codecs,
      server_decoders: active_codecs,
      negotiation_id: generate_negotiation_id(),
      protocol_version: 1
    }
  end

  @doc """
  Proposes capability negotiation from client hello fields.
  """
  def propose(%__MODULE__{} = neg, client_version, client_encoders, client_decoders) do
    hello = %{
      "protocol_version" => client_version,
      "encoders" => client_encoders,
      "decoders" => client_decoders
    }

    case handle_client_hello(neg, hello) do
      {:ok, updated_neg, _server_hello} ->
        {:ok,
         %{
           updated_neg
           | chosen_c2s_algorithm: updated_neg.client_to_server,
             chosen_s2c_algorithm: updated_neg.server_to_client,
             protocol_version: client_version
         }}

      err ->
        err
    end
  end

  @doc """
  Confirms and activates the negotiated capability set.
  """
  def confirm(%__MODULE__{} = neg) do
    ready = %{"negotiation_id" => neg.negotiation_id}

    case handle_client_ready(neg, ready) do
      {:ok, active_neg, _server_ready} ->
        {:ok,
         %{
           active_neg
           | chosen_c2s_algorithm: active_neg.client_to_server,
             chosen_s2c_algorithm: active_neg.server_to_client
         }}

      err ->
        err
    end
  end

  @doc """
  Processes a ClientHello map and computes the directional algorithm selections.
  """
  @spec handle_client_hello(t(), map()) :: {:ok, t(), map()} | {:error, atom()}
  def handle_client_hello(%__MODULE__{state: :await_hello} = neg, %{} = hello) do
    client_encoders = normalize_algorithm_list(hello["encoders"] || hello[:encoders] || hello["client_encoders"] || hello[:client_encoders] || [])
    client_decoders = normalize_algorithm_list(hello["decoders"] || hello[:decoders] || hello["client_decoders"] || hello[:client_decoders] || [])
    version = hello["protocol_version"] || hello[:protocol_version] || 1

    # Compute directional intersections
    c2s_candidates = intersection(client_encoders, neg.server_decoders)
    s2c_candidates = intersection(neg.server_encoders, client_decoders)

    selected_c2s = select_best(c2s_candidates, neg.server_decoders)
    selected_s2c = select_best(s2c_candidates, neg.server_encoders)

    updated_neg = %__MODULE__{
      neg
      | state: :hello_negotiated,
        client_encoders: client_encoders,
        client_decoders: client_decoders,
        client_to_server: selected_c2s,
        server_to_client: selected_s2c,
        chosen_c2s_algorithm: selected_c2s,
        chosen_s2c_algorithm: selected_s2c,
        protocol_version: version
    }

    server_hello = %{
      "type" => "server_hello",
      "negotiation_id" => updated_neg.negotiation_id,
      "selected_client_to_server" => Atom.to_string(selected_c2s),
      "selected_server_to_client" => Atom.to_string(selected_s2c),
      "server_encoders" => Enum.map(updated_neg.server_encoders, &Atom.to_string/1),
      "server_decoders" => Enum.map(updated_neg.server_decoders, &Atom.to_string/1)
    }

    {:ok, updated_neg, server_hello}
  end

  def handle_client_hello(%__MODULE__{}, _invalid), do: {:error, :invalid_state}

  @doc """
  Processes ClientReady and activates the negotiated compression algorithms.
  """
  @spec handle_client_ready(t(), map()) :: {:ok, t(), map()} | {:error, atom()}
  def handle_client_ready(%__MODULE__{state: :hello_negotiated} = neg, %{} = ready) do
    ready_id = ready["negotiation_id"] || ready[:negotiation_id]

    if ready_id == nil or ready_id == neg.negotiation_id do
      active_neg = %__MODULE__{
        neg
        | state: :active,
          chosen_c2s_algorithm: neg.client_to_server,
          chosen_s2c_algorithm: neg.server_to_client
      }

      server_ready = %{
        "type" => "server_ready",
        "negotiation_id" => neg.negotiation_id,
        "status" => "active"
      }

      {:ok, active_neg, server_ready}
    else
      {:error, :negotiation_id_mismatch}
    end
  end

  def handle_client_ready(%__MODULE__{}, _), do: {:error, :invalid_state}

  @doc """
  Checks if a message's compression algorithm is valid for incoming client-to-server traffic.
  """
  @spec validate_inbound_algorithm(t(), algorithm()) :: :ok | {:error, atom()}
  def validate_inbound_algorithm(%__MODULE__{state: :active, client_to_server: expected}, actual) do
    if expected == actual or actual == :none do
      :ok
    else
      {:error, {:unexpected_inbound_algorithm, actual, expected: expected}}
    end
  end

  def validate_inbound_algorithm(%__MODULE__{state: state}, _actual) when state != :active do
    {:error, :compression_not_active}
  end

  # --- Internal Helpers ---

  defp select_best(candidates, priority_list) do
    Enum.find(priority_list, :none, fn algo -> algo in candidates end)
  end

  defp intersection(list_a, list_b) do
    Enum.filter(list_a, &(&1 in list_b))
  end

  defp normalize_algorithm_list(list) when is_list(list) do
    list
    |> Enum.map(&to_algo_atom/1)
    |> Enum.filter(&(&1 != nil))
    |> Enum.uniq()
    |> Kernel.++([:none])
    |> Enum.uniq()
  end

  defp normalize_algorithm_list(_), do: [:none]

  defp to_algo_atom(:none), do: :none
  defp to_algo_atom(:gzip), do: :gzip
  defp to_algo_atom(:brotli), do: :brotli
  defp to_algo_atom(:zstd), do: :zstd
  defp to_algo_atom("none"), do: :none
  defp to_algo_atom("gzip"), do: :gzip
  defp to_algo_atom("brotli"), do: :brotli
  defp to_algo_atom("zstd"), do: :zstd
  defp to_algo_atom(_), do: nil

  defp available_server_codecs do
    # Only advertise codecs whose decoder enforces an output cap during decompression.
    # Brotli/Zstd remain unavailable until bounded streaming APIs are verified.
    [{None, :none}, {Gzip, :gzip}]
    |> Enum.filter(fn {mod, _name} -> mod.available?() end)
    |> Enum.map(fn {_mod, name} -> name end)
  end

  defp generate_negotiation_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
