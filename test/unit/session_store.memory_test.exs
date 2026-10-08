defmodule Frame.Unit.SessionStoreMemoryTest do
  use ExUnit.Case, async: true

  alias Frame.Adapters.LoginLimiter
  alias Frame.Adapters.SessionStore
  alias Frame.Adapters.SessionStore.Memory
  alias Frame.Domain.Session

  setup do
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-10-08 12:00:00Z] end)
    advance = fn s -> Agent.update(clock, &DateTime.add(&1, s)) end
    %{clock: fn -> Agent.get(clock, & &1) end, advance: advance}
  end

  test "create/fetch/revoke; kinds never mix", %{clock: clock} do
    store = Memory.new(clock: clock)
    pre = SessionStore.create(store, :pre)
    auth = SessionStore.create(store, :authenticated)
    assert byte_size(auth.id) == 43 and auth.id != auth.csrf_token
    assert {:ok, ^pre} = SessionStore.fetch(store, pre.id, :pre)
    assert SessionStore.fetch(store, pre.id, :authenticated) == :error
    assert SessionStore.fetch(store, auth.id, :pre) == :error
    assert {:ok, %Session{authenticated: true}} = SessionStore.fetch(store, auth.id, :authenticated)
    assert SessionStore.revoke(store, auth.id) == :ok
    assert SessionStore.fetch(store, auth.id, :authenticated) == :error
    assert SessionStore.fetch(store, "unknown", :pre) == :error
    assert SessionStore.fetch(store, nil, :pre) == :error
    assert SessionStore.policy(store) == Session.default_policy()
  end

  test "expired sessions are deleted on fetch and by the sweep", %{clock: clock, advance: advance} do
    store = Memory.new(clock: clock, policy: Session.policy(idle_seconds: 10))
    a = SessionStore.create(store, :authenticated)
    b = SessionStore.create(store, :authenticated)
    advance.(5)
    assert {:ok, _} = SessionStore.fetch(store, a.id, :authenticated)
    advance.(7)
    assert {:ok, _} = SessionStore.fetch(store, a.id, :authenticated)
    assert SessionStore.fetch(store, b.id, :authenticated) == :error
    advance.(11)
    assert Memory.sweep(store) == 0
    assert SessionStore.fetch(store, a.id, :authenticated) == :error
  end

  test "bounded: the least recently used record is evicted", %{clock: clock, advance: advance} do
    store = Memory.new(clock: clock, max_sessions: 3)
    [s1, s2, s3] = for _ <- 1..3, do: advance.(1) && SessionStore.create(store, :authenticated)
    advance.(1)
    {:ok, _} = SessionStore.fetch(store, s1.id, :authenticated)
    advance.(1)
    s4 = SessionStore.create(store, :pre)
    assert SessionStore.fetch(store, s2.id, :authenticated) == :error
    for s <- [s1, s3], do: assert({:ok, _} = SessionStore.fetch(store, s.id, :authenticated))
    assert {:ok, _} = SessionStore.fetch(store, s4.id, :pre)
  end

  test "supervised by name: store/1 + start_link/1, periodic sweep message" do
    opts = [table: :"sessions_#{System.unique_integer([:positive])}"]
    pid = start_supervised!(%{id: :store, start: {Memory, :start_link, [opts]}})
    store = Memory.store(opts)
    s = SessionStore.create(store, :pre)
    send(pid, :sweep)
    assert {:ok, _} = SessionStore.fetch(store, s.id, :pre)
  end

  test "login limiter: supervised by name and its handle" do
    name = :"limiter_#{System.unique_integer([:positive])}"
    start_supervised!({LoginLimiter.Memory, [name: name, limits: %{per_ip: 1}]})
    limiter = LoginLimiter.Memory.handle(name: name)
    assert LoginLimiter.check(limiter, "1.1.1.1") == :ok
    assert LoginLimiter.record_failure(limiter, "1.1.1.1") == :ok
    assert {:blocked, _} = LoginLimiter.check(limiter, "1.1.1.1")
    assert LoginLimiter.record_success(limiter, "1.1.1.1") == :ok
    assert LoginLimiter.check(limiter, "1.1.1.1") == :ok
    assert LoginLimiter.check(LoginLimiter.Memory.new(), "2.2.2.2") == :ok
  end
end
