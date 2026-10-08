defmodule Frame.Unit.SessionTest do
  use ExUnit.Case, async: true

  alias Frame.Domain.LoginThrottle
  alias Frame.Domain.Session

  @t0 ~U[2026-10-08 12:00:00Z]

  defp session(auth),
    do: %Session{id: "i", csrf_token: "c", authenticated: auth, created_at: @t0, last_seen_at: @t0}

  test "policy overrides may only shorten" do
    assert Session.default_policy() == %{
             idle_seconds: 1800,
             absolute_seconds: 28_800,
             pre_session_seconds: 3600
           }

    assert Session.policy(idle_seconds: 5, absolute_seconds: 99_999).idle_seconds == 5
    assert Session.policy(absolute_seconds: 99_999).absolute_seconds == 28_800
  end

  test "idle and absolute expiry" do
    p = Session.default_policy()
    s = session(true)
    assert Session.expires_at(s, p) == DateTime.add(@t0, 1800)
    refute Session.expired?(s, p, DateTime.add(@t0, 1799))
    assert Session.expired?(s, p, DateTime.add(@t0, 1800))

    # Used every 20 minutes: idle never hits, absolute does at 8 h.
    late = Session.touch(s, DateTime.add(@t0, 8 * 3600 - 60))
    assert Session.expires_at(late, p) == DateTime.add(@t0, 8 * 3600)
    assert Session.expired?(late, p, DateTime.add(@t0, 8 * 3600))
  end

  test "pre-sessions live one hour" do
    p = Session.default_policy()
    assert Session.expires_at(session(false), p) == DateTime.add(@t0, 3600)
  end

  describe "LoginThrottle" do
    test "5 invalid attempts per IP, then blocked with Retry-After" do
      t =
        Enum.reduce(
          1..5,
          LoginThrottle.new(),
          &LoginThrottle.record_failure(&2, "1.1.1.1", &1 * 1000)
        )

      assert {:blocked, retry} = LoginThrottle.check(t, "1.1.1.1", 6000)
      assert retry == 900 - 5
      assert LoginThrottle.check(t, "2.2.2.2", 6000) == :ok
      assert LoginThrottle.check(t, "1.1.1.1", 1000 + LoginThrottle.window_ms()) == :ok
    end

    test "success clears the IP; the instance limit still applies" do
      t = LoginThrottle.new(%{global: 3})
      t = Enum.reduce(1..3, t, &LoginThrottle.record_failure(&2, "ip#{&1}", &1))
      assert {:blocked, _} = LoginThrottle.check(t, "fresh", 10)

      t =
        LoginThrottle.record_success(LoginThrottle.new(), "x")
        |> LoginThrottle.record_failure("x", 1)

      assert LoginThrottle.record_success(t, "x").per_ip == %{}
    end

    test "memory is bounded and prune drops old entries" do
      t = LoginThrottle.new(%{max_tracked_ips: 3})
      t = Enum.reduce(1..10, t, &LoginThrottle.record_failure(&2, "ip#{&1}", &1))
      assert map_size(t.per_ip) == 3
      assert Map.has_key?(t.per_ip, "ip10")
      pruned = LoginThrottle.prune(t, 10 + LoginThrottle.window_ms())
      assert pruned.per_ip == %{} and pruned.global == []
    end
  end
end
