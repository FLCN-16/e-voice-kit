defmodule EVoiceKit.Auth.TokenTest do
  use ExUnit.Case, async: true

  alias EVoiceKit.Auth.Token

  describe "JWT Generation and Verification" do
    test "generates valid JWT with tenant, room, identity and permissions" do
      claims = %{
        "tenant_id" => "tenant_enterprise",
        "room" => "sales_conf",
        "identity" => "agent_smith",
        "permissions" => %{
          "can_publish" => true,
          "can_subscribe" => true,
          "can_publish_data" => false
        }
      }

      assert {:ok, token} = Token.generate(claims, ttl: 300)
      assert is_binary(token)
      assert length(String.split(token, ".")) == 3

      assert {:ok, verified_claims} = Token.verify(token)
      assert verified_claims["tenant_id"] == "tenant_enterprise"
      assert verified_claims["room"] == "sales_conf"
      assert verified_claims["identity"] == "agent_smith"
      assert verified_claims["permissions"]["can_publish"] == true
      assert verified_claims["permissions"]["can_publish_data"] == false
      assert verified_claims["exp"] > System.system_time(:second)
    end

    test "rejects tampered signature" do
      claims = %{"room" => "vip_room", "identity" => "ceo"}
      assert {:ok, token} = Token.generate(claims)

      [header, payload, _sig] = String.split(token, ".")
      tampered_token = header <> "." <> payload <> "." <> "bad_signature_bytes"

      assert {:error, :invalid_signature} = Token.verify(tampered_token)
    end

    test "rejects expired token" do
      claims = %{"room" => "test_room", "identity" => "bob"}
      now = System.system_time(:second)

      # Create token that expired 10 seconds ago
      assert {:ok, token} = Token.generate(claims, ttl: -10)
      assert {:error, :token_expired} = Token.verify(token, current_time: now)
    end

    test "refuses missing, weak, and known development secrets" do
      claims = %{"tenant_id" => "tenant", "room" => "room", "identity" => "user"}
      assert {:error, :weak_auth_secret} = Token.generate(claims, secret: "short")
      assert {:error, :insecure_auth_secret} =
               Token.generate(claims, secret: "evk_default_development_secret_change_in_production")
      assert {:error, :missing_auth_secret} = Token.verify("a.b.c", secret: nil)
      assert {:ok, non_expiring} = Token.generate(%{"exp" => nil})
      assert {:error, :missing_expiration} = Token.verify(non_expiring)
    end

    test "rejects malformed token strings" do
      assert {:error, :malformed_token} = Token.verify("not-a-token")
      assert {:error, :invalid_token_type} = Token.verify(nil)
      assert {:error, :invalid_token_type} = Token.verify(12345)
    end
  end
end
