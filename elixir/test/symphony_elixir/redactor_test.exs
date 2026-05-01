defmodule SymphonyElixir.RedactorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Redactor

  test "redacts sensitive nested values while preserving safe shapes" do
    timestamp = ~U[2026-05-01 00:00:00Z]

    assert Redactor.redact(%{
             1 => "numeric-key",
             safe: "visible",
             count: 3,
             token: "secret-token",
             credentials: %{username: "user", password: "p4ss"},
             private_key: ["line1", "line2"],
             session_token: timestamp,
             nested: [%{api_key: "sk-live-secret"}, %{url: "https://example.org/plain"}]
           }) == %{
             1 => "numeric-key",
             safe: "visible",
             count: 3,
             token: "[REDACTED]",
             credentials: "[REDACTED]",
             private_key: "[REDACTED]",
             session_token: "[REDACTED]",
             nested: [%{api_key: "[REDACTED]"}, %{url: "https://example.org/plain"}]
           }
  end

  test "redacts JSON string payloads and freeform secret patterns" do
    json =
      ~s({"api_key":"sk-live-secret","password":"p4ss","items":[{"access_token":"tok"}],"url":"https://user:pass@example.org?token=abc123"})

    redacted_json = Redactor.redact(json)

    refute redacted_json =~ "sk-live-secret"
    refute redacted_json =~ "p4ss"
    refute redacted_json =~ ~s("tok")
    refute redacted_json =~ "user:pass"
    refute redacted_json =~ "token=abc123"
    assert redacted_json =~ "[REDACTED]"

    freeform =
      "Authorization: Bearer live-token OPENAI_API_KEY=sk-live " <>
        "https://user:pass@example.org/path?client_secret=abc"

    assert Redactor.redact(freeform) ==
             "Authorization: Bearer [REDACTED] OPENAI_API_KEY=[REDACTED] " <>
               "https://[REDACTED]:[REDACTED]@example.org/path?client_secret=[REDACTED]"
  end

  test "redacts token-bearing URLs and standalone provider tokens" do
    value =
      "callback=https://example.org/cb?id_token=id.jwt.secret&refresh_token=refresh-secret" <>
        "&session_token=session-secret saw sk-live1234567890 and github_pat_1234567890abcdefABCDE"

    redacted = Redactor.redact(value)

    refute redacted =~ "id.jwt.secret"
    refute redacted =~ "refresh-secret"
    refute redacted =~ "session-secret"
    refute redacted =~ "sk-live1234567890"
    refute redacted =~ "github_pat_1234567890abcdefABCDE"
    assert redacted =~ "id_token=[REDACTED]"
    assert redacted =~ "refresh_token=[REDACTED]"
    assert redacted =~ "session_token=[REDACTED]"
  end

  test "redacts secret-ish JSON string fields beyond exact key names" do
    value = ~s({"stripe_secret":"sk-live1234567890","nested_access_token":"tok-secret","safe":"visible"})

    redacted = Redactor.redact(value)

    refute redacted =~ "sk-live1234567890"
    refute redacted =~ "tok-secret"
    assert redacted =~ ~s("safe":"visible")
  end

  test "leaves scalar, struct, and non-secret JSON values intact" do
    timestamp = ~U[2026-05-01 00:00:00Z]

    assert Redactor.redact(42) == 42
    assert Redactor.redact(timestamp) == timestamp
    assert Redactor.redact(~s(["safe","values"])) == ~s(["safe","values"])
  end
end
