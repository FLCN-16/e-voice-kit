defmodule EVoiceKit.Signaling.Protocol do
  @moduledoc """
  Protocol message types, error codes, and serialization helpers for E-Voice-Kit native signaling.

  See `docs/ELIXIR_REALTIME_SERVER_TECHNICAL_DESIGN.md` (Section 7).
  """

  # Message Types (16-bit unsigned integers)
  @msg_client_hello 1
  @msg_server_hello 2
  @msg_client_ready 3
  @msg_server_ready 4

  @msg_join_room 10
  @msg_join_room_response 11
  @msg_leave_room 12
  @msg_participant_joined 13
  @msg_participant_left 14

  @msg_sdp_offer 20
  @msg_sdp_answer 21
  @msg_trickle_ice 22

  @msg_publish_track 30
  @msg_track_published 31
  @msg_unpublish_track 32
  @msg_subscribe_track 33
  @msg_track_subscribed 34
  @msg_unsubscribe_track 35

  @msg_data_packet 40
  @msg_ping 50
  @msg_pong 51
  @msg_error 99

  # Error Codes
  @err_auth_failed 1001
  @err_room_not_found 1002
  @err_room_full 1003
  @err_duplicate_participant 1004
  @err_track_not_found 1005
  @err_permission_denied 1006
  @err_compression_mismatch 1007
  @err_malformed_frame 1008
  @err_sdp_rejected 1009
  @err_internal_error 1010

  # Getters for message types
  def msg_type(:client_hello), do: @msg_client_hello
  def msg_type(:server_hello), do: @msg_server_hello
  def msg_type(:client_ready), do: @msg_client_ready
  def msg_type(:server_ready), do: @msg_server_ready
  def msg_type(:join_room), do: @msg_join_room
  def msg_type(:join_room_response), do: @msg_join_room_response
  def msg_type(:leave_room), do: @msg_leave_room
  def msg_type(:participant_joined), do: @msg_participant_joined
  def msg_type(:participant_left), do: @msg_participant_left
  def msg_type(:sdp_offer), do: @msg_sdp_offer
  def msg_type(:sdp_answer), do: @msg_sdp_answer
  def msg_type(:trickle_ice), do: @msg_trickle_ice
  def msg_type(:publish_track), do: @msg_publish_track
  def msg_type(:track_published), do: @msg_track_published
  def msg_type(:unpublish_track), do: @msg_unpublish_track
  def msg_type(:subscribe_track), do: @msg_subscribe_track
  def msg_type(:track_subscribed), do: @msg_track_subscribed
  def msg_type(:unsubscribe_track), do: @msg_unsubscribe_track
  def msg_type(:data_packet), do: @msg_data_packet
  def msg_type(:ping), do: @msg_ping
  def msg_type(:pong), do: @msg_pong
  def msg_type(:error), do: @msg_error
  def msg_type(_), do: 0

  def msg_name(@msg_client_hello), do: :client_hello
  def msg_name(@msg_server_hello), do: :server_hello
  def msg_name(@msg_client_ready), do: :client_ready
  def msg_name(@msg_server_ready), do: :server_ready
  def msg_name(@msg_join_room), do: :join_room
  def msg_name(@msg_join_room_response), do: :join_room_response
  def msg_name(@msg_leave_room), do: :leave_room
  def msg_name(@msg_participant_joined), do: :participant_joined
  def msg_name(@msg_participant_left), do: :participant_left
  def msg_name(@msg_sdp_offer), do: :sdp_offer
  def msg_name(@msg_sdp_answer), do: :sdp_answer
  def msg_name(@msg_trickle_ice), do: :trickle_ice
  def msg_name(@msg_publish_track), do: :publish_track
  def msg_name(@msg_track_published), do: :track_published
  def msg_name(@msg_unpublish_track), do: :unpublish_track
  def msg_name(@msg_subscribe_track), do: :subscribe_track
  def msg_name(@msg_track_subscribed), do: :track_subscribed
  def msg_name(@msg_unsubscribe_track), do: :unsubscribe_track
  def msg_name(@msg_data_packet), do: :data_packet
  def msg_name(@msg_ping), do: :ping
  def msg_name(@msg_pong), do: :pong
  def msg_name(@msg_error), do: :error
  def msg_name(_), do: :unknown

  # Getters for error codes
  def error_code(:auth_failed), do: @err_auth_failed
  def error_code(:unauthorized), do: @err_auth_failed
  def error_code(:room_not_found), do: @err_room_not_found
  def error_code(:room_full), do: @err_room_full
  def error_code(:duplicate_participant), do: @err_duplicate_participant
  def error_code(:track_not_found), do: @err_track_not_found
  def error_code(:permission_denied), do: @err_permission_denied
  def error_code(:compression_mismatch), do: @err_compression_mismatch
  def error_code(:malformed_frame), do: @err_malformed_frame
  def error_code(:sdp_rejected), do: @err_sdp_rejected
  def error_code(:negotiation_failed), do: @err_sdp_rejected
  def error_code(:frame_decode_error), do: @err_malformed_frame
  def error_code(:internal_error), do: @err_internal_error
  def error_code(_), do: @err_internal_error

  @doc """
  Builds a structured protocol error map.
  """
  @spec build_error(atom(), String.t(), non_neg_integer()) :: map()
  def build_error(reason, message, request_id \\ 0) do
    %{
      "type" => "error",
      "code" => error_code(reason),
      "reason" => Atom.to_string(reason),
      "message" => message,
      "request_id" => request_id
    }
  end
end
