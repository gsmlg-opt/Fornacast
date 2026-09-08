defmodule ForgeGitHub.PullCreateWorkerTest do
  use ExUnit.Case, async: true
  alias ForgeGitHub.{InstallationToken, PullCreateRecovery, PullCreateWorker}
  alias ForgeMirrors.{CorrelationMarker, MirrorOperation, PullCreationIntent}

  setup do
    now = DateTime.utc_now(:second)
    uuid = Ecto.UUID.generate()
    {:ok, transport_body} = CorrelationMarker.append(nil, uuid)
    desired_body = String.duplicate("界", 65_536)

    fields = %{
      "title" => "Desired",
      "body" => desired_body,
      "state" => "closed",
      "state_reason" => "completed",
      "draft" => true,
      "head_ref" => "refs/heads/feature",
      "head_sha" => String.duplicate("b", 40),
      "base_ref" => "refs/heads/main",
      "base_sha" => String.duplicate("a", 40)
    }

    repositories = %{
      "base_repository" => %{"id" => 10, "node_id" => "R_base"},
      "head_repository" => %{"id" => 20, "node_id" => "R_head"}
    }

    issue_fields =
      Map.take(fields, ~w(title body state state_reason))
      |> Map.merge(%{"label_github_ids" => [], "assignee_github_ids" => []})

    proof = %{
      base: %{repository_id: 1, ref: fields["base_ref"], oid: fields["base_sha"]},
      head: %{repository_id: 2, ref: fields["head_ref"], oid: fields["head_sha"]}
    }

    intent = %PullCreationIntent{
      id: 1,
      pull_id: 12,
      issue_id: 11,
      repository_id: 1,
      repository_mirror_id: 3,
      local_version: 1,
      creation_uuid: uuid,
      payload: %{
        "pull_snapshot" => fields,
        "issue_snapshot" => issue_fields,
        "provider_repositories" => repositories,
        "merge_state" => %{"merged_at" => nil, "merge_commit_sha" => nil}
      }
    }

    marker = %{
      "action" => "create_remote_pull",
      "phase" => "unresolved",
      "creation_uuid" => uuid,
      "intent_id" => 1
    }

    operation = %MirrorOperation{
      id: 1,
      kind: "sync.pull",
      state: :processing,
      checkpoint: %{},
      cursor: %{"trigger" => "local"}
    }

    marked = %{operation | state: :effect_pending, external_effect_marker: marker}

    sync = %{
      mode: :outbound_create,
      phase: :unmarked,
      repository_id: 1,
      repository_mirror_id: 3,
      github_installation_id: System.unique_integer([:positive]),
      remote_owner: "acme",
      remote_repository: "base",
      git_proof: proof,
      pull_id: 12,
      issue_id: 11,
      expected_local_version: 1,
      expected_fields: fields,
      expected_issue_snapshot: issue_fields,
      expected_merge_state: %{merged_at: nil, merge_commit_sha: nil},
      provider_repositories: repositories,
      pull_eligibility_proof: %{},
      routing: %{
        base: %{remote_owner: "acme", remote_repository: "base"},
        head: %{remote_owner: "acme", remote_repository: "head"}
      }
    }

    recovery =
      Map.merge(sync, %{
        phase: :recovery,
        intent: intent,
        marker: marker,
        recovery_checkpoint: PullCreateRecovery.initial()
      })

    stub = {__MODULE__, System.unique_integer([:positive])}

    options = [
      client_options: [
        plug: {Req.Test, stub},
        resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
      ],
      token_fetch: fn _, %{permissions: permissions} ->
        assert permissions["issues"] == "write"
        assert permissions["contents"] == "read"

        %InstallationToken{
          token: "fixture-installation-token",
          expires_at: DateTime.add(now, 3600),
          permissions: permissions
        }
      end,
      with_ref_fences: fn _, fun ->
        send(self(), :fenced)
        fun.()
      end,
      provider_refs: fn _, _token, _opts -> :ok end,
      mark: fn _, _, _ ->
        send(self(), :marked)
        {:ok, %{operation: marked, intent: intent, marker: marker, newly_marked: true}}
      end,
      recovery_context: fn op -> {:ok, %{recovery | marker: op.external_effect_marker}} end,
      identify: fn op, _, _, pair ->
        send(self(), {:identified, pair})

        identity = %{
          "github_object_id" => pair.pull.github_object_id,
          "github_node_id" => pair.pull.github_node_id,
          "github_issue_object_id" => pair.issue.github_object_id,
          "github_issue_node_id" => pair.issue.github_node_id,
          "github_number" => 7
        }

        updated = %{
          op
          | external_effect_marker:
              Map.merge(op.external_effect_marker, %{
                "phase" => "identified",
                "remote_identity" => identity
              })
        }

        {:ok, %{operation: updated, marker: updated.external_effect_marker, intent: intent}}
      end,
      checkpoint: fn op, old, next, _, _ ->
        send(self(), {:checkpoint, old, next})

        {:ok,
         %{
           op
           | checkpoint: Map.put(op.checkpoint, "pull_creation_recovery", next),
             lease_owner: nil
         }}
      end,
      conflict: fn op, _, marker, kind, evidence ->
        assert marker == op.external_effect_marker
        send(self(), {:conflicted, marker, kind, evidence})
        {:ok, %{operation: %{op | state: :failed}}}
      end,
      defer: fn op, _, _, _, code ->
        send(self(), {:deferred, op.external_effect_marker, code})
        {:ok, op}
      end,
      relationship_attrs: fn _, _, _, _ -> {:ok, %{"labels" => [], "assignees" => []}} end,
      confirm: fn op, _, _, pair, callback ->
        assert is_function(callback, 1)
        send(self(), {:confirmed, pair})
        {:ok, %{operation: %{op | state: :completed}}}
      end
    ]

    %{
      now: now,
      operation: operation,
      marked: marked,
      sync: sync,
      recovery: recovery,
      intent: intent,
      marker: marker,
      body: desired_body,
      transport_body: transport_body,
      stub: stub,
      options: options
    }
  end

  test "first committed admission POSTs only marker body and pins paired IDs before yielding",
       c do
    Req.Test.stub(c.stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/repos/acme/base/pulls"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          attrs = JSON.decode!(body)
          assert attrs["body"] == c.transport_body
          assert attrs["head"] == "acme:feature"
          assert attrs["head_repo"] == "head"
          assert attrs["draft"]
          refute Map.has_key?(attrs, "state")
          send(self(), :posted)
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(pull(c, :transport))

        {"GET", "/repos/acme/base/pulls/7"} ->
          Req.Test.json(conn, pull(c, :transport))

        {"GET", "/repos/acme/base/issues/7"} ->
          Req.Test.json(conn, issue(c, :transport))

        other ->
          flunk("unexpected provider effect #{inspect(other)}")
      end
    end)

    assert {:ok, _} = run(c)
    assert_received :marked
    assert_received :posted

    assert_received {:identified,
                     %{pull: %{github_object_id: 700}, issue: %{github_object_id: 800}}}

    assert_received {:checkpoint, _, _}
    refute_received :posted
    refute_received {:confirmed, _}
  end

  test "ambiguous POST retains marked operation and never retries POST", c do
    Req.Test.stub(c.stub, fn conn ->
      assert conn.method == "POST"
      send(self(), :posted)
      Plug.Conn.send_resp(conn, 503, "unavailable")
    end)

    assert {:ok, _} = run(c)
    assert_received {:deferred, marker, _}
    assert marker == c.marker
    assert_received :posted
    refute_received :posted
  end

  test "recovery scans one full-list page and persists zero-match completion without POST", c do
    Req.Test.stub(c.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/base/pulls"
      assert Plug.Conn.fetch_query_params(conn).query_params["state"] == "all"
      Req.Test.json(conn, [])
    end)

    assert {:ok, _} = run_recovery(c)
    assert_received {:checkpoint, _, %{"complete" => true, "candidate" => nil}}
    refute_received :marked
  end

  test "a completed empty scan becomes a visible conflict without another creator", c do
    recovery = %{
      c.recovery
      | recovery_checkpoint: %{"page" => 1, "candidate" => nil, "complete" => true}
    }

    assert {:ok, _} = PullCreateWorker.process_operation(c.marked, c.now, recovery, c.options)

    assert_received {:conflicted, _, "ambiguous_external_effect",
                     %{"reason" => "zero_complete_scan"}}

    refute_received {:deferred, _, _}
    refute_received :marked
  end

  test "multiple UUID matches become evidence, never an arbitrary provider binding", c do
    Req.Test.stub(c.stub, fn conn ->
      assert conn.method == "GET"
      first = pull(c, :transport)
      second = Map.merge(first, %{"id" => 701, "node_id" => "PR_701", "number" => 8})
      Req.Test.json(conn, [first, second])
    end)

    assert {:ok, _} = run_recovery(c)

    assert_received {:conflicted, _, "ambiguous_external_effect",
                     %{"reason" => "multiple_uuid_matches", "candidates" => candidates}}

    assert Enum.map(candidates, & &1["github_object_id"]) == [700, 701]
    refute_received {:identified, _}
    refute_received :marked
  end

  test "identified cleanup PATCH uses full maximum body, closes desired state, and confirms fresh paired GET",
       c do
    c = identified(c)
    Process.put(:cleaned, false)

    Req.Test.stub(c.stub, fn conn ->
      phase = if Process.get(:cleaned), do: :desired, else: :transport

      case {conn.method, conn.request_path} do
        {"GET", "/repos/acme/base/pulls/7"} ->
          Req.Test.json(conn, pull(c, phase))

        {"GET", "/repos/acme/base/issues/7"} ->
          Req.Test.json(conn, issue(c, phase))

        {"PATCH", "/repos/acme/base/issues/7"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn, length: 300_000)
          attrs = JSON.decode!(body)
          assert attrs["body"] == c.body
          assert attrs["state"] == "closed"
          assert attrs["state_reason"] == "completed"
          assert attrs["labels"] == [] and attrs["assignees"] == []
          Process.put(:cleaned, true)
          send(self(), :patched)
          Req.Test.json(conn, issue(c, :desired))

        other ->
          flunk("unexpected request #{inspect(other)}")
      end
    end)

    assert {:ok, %{operation: %{state: :completed}}} = run_recovery(c)
    assert_received :patched
    assert_received {:confirmed, %{pull: %{confirmed_snapshot: %{"body" => body}}}}
    assert body == c.body
    refute_received :marked
  end

  test "already-cleaned identified effect only GETs and confirms", c do
    c = identified(c)

    Req.Test.stub(c.stub, fn conn ->
      assert conn.method == "GET"

      Req.Test.json(
        conn,
        if(String.contains?(conn.request_path, "/pulls/"),
          do: pull(c, :desired),
          else: issue(c, :desired)
        )
      )
    end)

    assert {:ok, _} = run_recovery(c)
    assert_received {:confirmed, _}
  end

  test "third-party cleanup shape records a visible conflict with its remote snapshot",
       c do
    c = identified(c)

    Req.Test.stub(c.stub, fn conn ->
      assert conn.method == "GET"

      raw =
        if String.contains?(conn.request_path, "/pulls/"),
          do: pull(c, :transport),
          else: issue(c, :transport)

      Req.Test.json(conn, Map.put(raw, "body", "third-party"))
    end)

    assert {:ok, _} = run_recovery(c)

    assert_received {:conflicted, _, "third_party_metadata",
                     %{"reason" => "third_party_metadata", "observation" => observation}}

    assert observation["pull_snapshot"]["body"] == "third-party"
    refute_received {:deferred, _, _}
    refute_received {:confirmed, _}
  end

  test "substituted identified provider IDs conflict without PATCH", c do
    c = identified(c)

    Req.Test.stub(c.stub, fn conn ->
      assert conn.method == "GET"

      raw =
        if String.contains?(conn.request_path, "/pulls/"),
          do: Map.put(pull(c, :transport), "id", 701),
          else: issue(c, :transport)

      Req.Test.json(conn, raw)
    end)

    assert {:ok, _} = run_recovery(c)
    assert_received {:conflicted, _, "identity_conflict", %{"reason" => "pair_mismatch"}}
    refute_received {:confirmed, _}
    refute_received {:deferred, _, _}
  end

  test "inactive recovery context cannot PATCH or confirm and retains old marker", c do
    c = identified(c)
    opts = Keyword.put(c.options, :recovery_context, fn _ -> {:error, :ineligible_pull} end)
    assert {:ok, _} = PullCreateWorker.process_operation(c.marked, c.now, c.recovery, opts)
    assert_received {:deferred, marker, _}
    assert marker == c.marked.external_effect_marker
  end

  test "lease loss while provider preflight is in flight prevents cleanup PATCH", c do
    c = identified(c)
    Process.put(:contexts, 0)

    opts =
      Keyword.put(c.options, :recovery_context, fn op ->
        calls = Process.get(:contexts) + 1
        Process.put(:contexts, calls)

        if calls < 3,
          do: {:ok, %{c.recovery | marker: op.external_effect_marker}},
          else: {:error, :lost_lease}
      end)

    Req.Test.stub(c.stub, fn conn ->
      assert conn.method == "GET", "cleanup must recheck lease after slow provider reads"

      Req.Test.json(
        conn,
        if(String.contains?(conn.request_path, "/pulls/"),
          do: pull(c, :transport),
          else: issue(c, :transport)
        )
      )
    end)

    assert {:ok, _} = PullCreateWorker.process_operation(c.marked, c.now, c.recovery, opts)
    assert Process.get(:contexts) == 3
    refute_received {:confirmed, _}
  end

  test "cleanup preserves supported relationship sets larger than one listing page", c do
    c = identified(c)
    ids = Enum.to_list(1..101)

    intent = %{
      c.intent
      | payload: put_in(c.intent.payload, ["issue_snapshot", "label_github_ids"], ids)
    }

    c = %{c | intent: intent, recovery: %{c.recovery | intent: intent}}

    opts =
      c.options
      |> Keyword.put(:label_node_context, fn _ -> {:ok, %{status: :ready}} end)
      |> Keyword.put(:recovery_context, fn op ->
        {:ok, %{c.recovery | marker: op.external_effect_marker}}
      end)
      |> Keyword.put(:relationship_attrs, fn _, _, _, _ ->
        {:ok, %{"labels" => Enum.map(ids, &"label-#{&1}"), "assignees" => []}}
      end)

    Process.put(:cleaned, false)

    Req.Test.stub(c.stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"PATCH", "/repos/acme/base/issues/7"} ->
          {:ok, encoded, conn} = Plug.Conn.read_body(conn, length: 300_000)
          assert length(JSON.decode!(encoded)["labels"]) == 101
          Process.put(:cleaned, true)

          Req.Test.json(
            conn,
            Map.put(
              issue(c, :desired),
              "labels",
              Enum.map(ids, &%{"id" => &1, "node_id" => "L_#{&1}", "name" => "label-#{&1}"})
            )
          )

        {"GET", path} ->
          phase = if Process.get(:cleaned), do: :desired, else: :transport
          raw = if String.contains?(path, "/pulls/"), do: pull(c, phase), else: issue(c, phase)

          raw =
            if phase == :desired and String.contains?(path, "/issues/"),
              do:
                Map.put(
                  raw,
                  "labels",
                  Enum.map(ids, &%{"id" => &1, "node_id" => "L_#{&1}", "name" => "label-#{&1}"})
                ),
              else: raw

          Req.Test.json(conn, raw)
      end
    end)

    assert {:ok, %{operation: %{state: :completed}}} =
             PullCreateWorker.process_operation(c.marked, c.now, c.recovery, opts)

    assert_received {:confirmed, %{issue: %{confirmed_snapshot: %{"label_github_ids" => ^ids}}}}
  end

  test "cleanup seeds one missing assignee by immutable ID and yields without PATCH", c do
    c = identified(c)

    intent = %{
      c.intent
      | payload: put_in(c.intent.payload, ["issue_snapshot", "assignee_github_ids"], [42])
    }

    c = %{c | intent: intent, recovery: %{c.recovery | intent: intent}}
    target = %{identity_id: 5, github_user_id: 42, expected_node_id: nil}

    opts =
      c.options
      |> Keyword.put(:recovery_context, fn op ->
        {:ok, %{c.recovery | marker: op.external_effect_marker}}
      end)
      |> Keyword.put(:assignee_node_context, fn op ->
        {:ok, %{target: target, marker: op.external_effect_marker}}
      end)
      |> Keyword.put(:seed_assignee_node, fn op, _, expected, user ->
        assert expected == %{marker: op.external_effect_marker, target: target}
        assert user.id == 42 and user.node_id == "U_42" and user.login == "renamed"
        send(self(), :seeded_assignee)
        {:ok, %{operation: %{op | lease_owner: nil}, identity: user}}
      end)

    Req.Test.stub(c.stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/user/42"} ->
          Req.Test.json(conn, %{"id" => 42, "node_id" => "U_42", "login" => "renamed"})

        {"GET", path} ->
          Req.Test.json(
            conn,
            if(String.contains?(path, "/pulls/"),
              do: pull(c, :transport),
              else: issue(c, :transport)
            )
          )

        _ ->
          flunk("node preparation must not mutate provider metadata")
      end
    end)

    assert {:ok, %{operation: %{state: :effect_pending, lease_owner: nil}}} =
             PullCreateWorker.process_operation(c.marked, c.now, c.recovery, opts)

    assert_received :seeded_assignee
    refute_received {:confirmed, _}
  end

  test "failed assignee scope revalidation prevents lookup and cleanup", c do
    c = identified(c)

    intent = %{
      c.intent
      | payload: put_in(c.intent.payload, ["issue_snapshot", "assignee_github_ids"], [42])
    }

    c = %{c | intent: intent, recovery: %{c.recovery | intent: intent}}

    opts =
      c.options
      |> Keyword.put(:recovery_context, fn op ->
        {:ok, %{c.recovery | marker: op.external_effect_marker}}
      end)
      |> Keyword.put(:assignee_node_context, fn _ -> {:error, :stale_lease} end)
      |> Keyword.put(:seed_assignee_node, fn _, _, _, _ ->
        flunk("stale scope cannot seed identity")
      end)

    Req.Test.stub(c.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path in ["/repos/acme/base/pulls/7", "/repos/acme/base/issues/7"]

      Req.Test.json(
        conn,
        if(String.contains?(conn.request_path, "/pulls/"),
          do: pull(c, :transport),
          else: issue(c, :transport)
        )
      )
    end)

    assert {:ok, _} = PullCreateWorker.process_operation(c.marked, c.now, c.recovery, opts)
    assert_received {:deferred, _, _}
    refute_received {:confirmed, _}
  end

  defp run(c), do: PullCreateWorker.process_operation(c.operation, c.now, c.sync, c.options)

  defp run_recovery(c),
    do: PullCreateWorker.process_operation(c.marked, c.now, c.recovery, c.options)

  defp identified(c) do
    remote = %{
      "github_object_id" => 700,
      "github_node_id" => "PR_700",
      "github_issue_object_id" => 800,
      "github_issue_node_id" => "I_800",
      "github_number" => 7
    }

    marker = Map.merge(c.marker, %{"phase" => "identified", "remote_identity" => remote})

    %{
      c
      | marked: %{c.marked | external_effect_marker: marker},
        recovery: %{c.recovery | marker: marker}
    }
  end

  defp pull(c, phase) do
    %{
      "id" => 700,
      "node_id" => "PR_700",
      "number" => 7,
      "title" => "Desired",
      "body" => body(c, phase),
      "state" => state(phase),
      "draft" => true,
      "user" => user(),
      "created_at" => "2030-01-01T00:00:00Z",
      "updated_at" => "2030-01-02T00:00:00Z",
      "closed_at" => nil,
      "merged_at" => nil,
      "merge_commit_sha" => nil,
      "merged" => false,
      "mergeable" => true,
      "rebaseable" => true,
      "mergeable_state" => "clean",
      "base" => %{
        "ref" => "main",
        "sha" => String.duplicate("a", 40),
        "repo" => %{"id" => 10, "node_id" => "R_base", "full_name" => "acme/base"}
      },
      "head" => %{
        "ref" => "feature",
        "sha" => String.duplicate("b", 40),
        "repo" => %{"id" => 20, "node_id" => "R_head", "full_name" => "acme/head"}
      }
    }
  end

  defp issue(c, phase) do
    %{
      "id" => 800,
      "node_id" => "I_800",
      "number" => 7,
      "title" => "Desired",
      "body" => body(c, phase),
      "state" => state(phase),
      "state_reason" => if(phase == :desired, do: "completed"),
      "labels" => [],
      "assignees" => [],
      "user" => user(),
      "created_at" => "2030-01-01T00:00:00Z",
      "updated_at" => "2030-01-02T00:00:00Z",
      "closed_at" => nil,
      "pull_request" => %{
        "url" => "https://api.github.com/repos/acme/base/pulls/7",
        "html_url" => "https://github.com/acme/base/pull/7",
        "diff_url" => "https://github.com/acme/base/pull/7.diff",
        "patch_url" => "https://github.com/acme/base/pull/7.patch"
      }
    }
  end

  defp body(c, :transport), do: c.transport_body
  defp body(c, :desired), do: c.body
  defp state(:transport), do: "open"
  defp state(:desired), do: "closed"
  defp user, do: %{"id" => 99, "node_id" => "U_99", "login" => "octocat"}
end
