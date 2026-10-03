defmodule Courier.KitTenantIsolationProbeTest do
  @moduledoc """
  THE CROSS-TENANT NEGATIVE SUITE. Copied in by kit's harness
  (`tests/tenant_isolation/`), not committed to courier.

  ## What this file is

  Two accounts, seeded through courier's own write path, and six assertions that
  account A cannot reach account B's rows. Each assertion is named after the
  breakage it is the control for, because kit's recipe plants a defect and
  asserts that THIS test goes red — a control that could be caught by a
  different test proves the harness can fail and nothing about the check.

  ## Why it lives outside the service

  courier has 19 cross-tenant tests of its own and they all pass. The debt entry
  this answers is D18: *nothing proves one account cannot read another's data,
  and nothing can ask*. A service's own suite answers "did my change keep the
  behaviour" and cannot answer "does this service still hold, today". The harness
  is the second question, it belongs to the fleet standard so every service gets
  it by adopting kit, and it deliberately shares no assertion code with the
  service's own tests — a shared assertion is one place to make both green.

  ## Why the tests are NOT inside a `describe` block

  ExUnit prefixes a failure header with its enclosing `describe`, so a test
  inside one is reported as `test <describe> <name>` rather than `test <name>`.
  The recipe asserts on the reported name, and a needle that has to carry the
  describe block's wording too is a needle that dies the first time anyone
  rewords a docstring.

  ## Why a context-level probe and not the controller

  It uses both, deliberately. `cross_tenant_list`, `fetch_by_id`, `update` and
  `delete` go through the real HTTP entry points with a real `current_account`
  assignment, because that is where an IDOR lives. `enabled/1` and `list/1` are
  called directly, because they are the delivery pipeline's own queries and no
  controller wraps them.

  ## The assertion set is THREE DENIALS AND ONE ALLOWANCE

  A harness with only denials is satisfied by a service that returns nothing to
  anybody, so `cross_tenant_list_own_row_visible` exists to fail when the scoping
  is *present but bound to the wrong account* — the breakage no grep can see,
  because the word `account_id` is still right there on the line.
  """

  use CourierWeb.ConnCase, async: false

  alias Courier.Repo
  alias Courier.WebhookEndpoints

  # Two accounts and one endpoint each, both written through courier's own
  # `create/1` so the seed goes through the same validation and the same query
  # layer the API uses. Seeded by an account_id that exists in no table, because
  # courier has no accounts table of its own yet — which is itself part of D18.
  @account_a "11111111-1111-4111-8111-111111111111"
  @account_b "22222222-2222-4222-8222-222222222222"
  @url_a "https://alpha.example.com/hooks"
  @url_b "https://bravo.example.com/hooks"

  setup do
    {:ok, own: seed(@account_a, @url_a), other: seed(@account_b, @url_b)}
  end

  defp seed(account_id, url) do
    {:ok, endpoint, _secret} = WebhookEndpoints.create(%{url: url, account_id: account_id})
    endpoint
  end

  # `Phoenix.ConnTest.build_conn/0`, not `Plug.Test.conn/3`, for the reason
  # courier's own controller test states: the verb helpers build the request conn
  # from the method and path, and a conn made with `Plug.Test` has no
  # `secret_key_base`, so everything the endpoint needs is discarded on the way
  # through. A header set on a `build_conn/0` survives, because that is the conn
  # the request is dispatched FROM.
  defp as(account_id), do: put_req_header(build_conn(), "x-courier-account", account_id)

  test "cross_tenant_list", %{own: own, other: other} do
    conn = get(as(@account_a), "/v1/webhook_endpoints")

    assert conn.status == 200

    body = json_response(conn, 200)
    ids = Enum.map(body["data"], & &1["id"])

    assert own.id in ids, "the allowance: A must see its OWN row"

    refute other.id in ids, "A's list must carry no row of B's"
  end

  test "cross_tenant_list_own_row_visible" do
    # The allowance as its OWN test, so a broken BIND is caught here and not
    # silently absorbed by the denial tests above. A predicate that is present
    # and pinned to the wrong account reads exactly like a correctly scoped
    # one to a grep, and reads as "zero rows" to everything else.
    rows = WebhookEndpoints.list(@account_a)

    assert Enum.map(rows, & &1.id) != [],
           "A's own list must not be empty; an empty one is a bind, not an isolation"

    assert Enum.all?(rows, &(&1.account_id == @account_a)),
           "A's list must carry only A's rows"
  end

  test "cross_tenant_fetch_by_id", %{other: other} do
    conn = get(as(@account_a), "/v1/webhook_endpoints/#{other.id}")

    # 404, never 403: a 403 confirms the id exists to somebody who cannot see
    # it, which is the enumeration oracle the 404 exists to withhold.
    assert conn.status == 404,
           "A fetching B's endpoint by id must be a 404, got #{conn.status}"
  end

  test "cross_tenant_update", %{other: other} do
    conn =
      patch(as(@account_a), "/v1/webhook_endpoints/#{other.id}", %{
        "description" => "hijacked by A"
      })

    assert conn.status == 404,
           "A updating B's endpoint must be a 404, got #{conn.status}"

    refute Repo.get(Courier.WebhookEndpoint, other.id).description == "hijacked by A",
           "B's row was modified by A"
  end

  test "cross_tenant_delete", %{other: other} do
    conn = delete(as(@account_a), "/v1/webhook_endpoints/#{other.id}")

    assert conn.status == 404,
           "A deleting B's endpoint must be a 404, got #{conn.status}"

    assert Repo.get(Courier.WebhookEndpoint, other.id) != nil, "B's row was deleted by A"
  end

  test "cross_tenant_enabled_list" do
    rows = WebhookEndpoints.enabled(@account_a)

    assert Enum.all?(rows, &(&1.account_id == @account_a)),
           "the delivery fan-out query must carry only A's enabled endpoints, " <>
             "got #{inspect(Enum.map(rows, & &1.url))}"
  end
end