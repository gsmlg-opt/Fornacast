defmodule GitLFS.PointerScanner do
  @moduledoc """
  Persists bounded, restartable traversal of Git objects that may contain LFS pointers.

  Git object expansion stays in `GitCore`; this context owns the durable per-ref work
  queue, pointer discoveries, and atomic publication of authoritative reachability.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias ForgeRepos.Repository
  alias Fornacast.Repo
  alias GitLFS.{LFSObject, Pointer, RepositoryObject}

  alias GitLFS.PointerScanner.{
    Reachability,
    Scan,
    ScanRef,
    WorkItem
  }

  @maximum_batch_limit 200
  @maximum_page_limit 100
  @default_batch_limit 200
  @default_lease_seconds 60
  @maximum_lease_seconds 3_600
  @git_oid_regex ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  @type baseline :: %{
          required(:ref_name) => String.t(),
          required(:ref_kind) => :branch | :tag,
          required(:oid) => String.t()
        }

  @type expansion :: %{
          required(:object_kind) => :commit | :tree | :blob | :tag,
          required(:children) => [%{required(:oid) => String.t(), required(:kind) => atom()}],
          required(:candidate) =>
            nil | %{required(:data) => binary(), required(:blob_size) => non_neg_integer()},
          required(:next_offset) => non_neg_integer() | nil
        }

  @spec begin_scan(Repository.t(), String.t(), [baseline()], keyword()) ::
          {:ok, Scan.t()} | {:error, atom() | {:validation, Changeset.t()}}
  def begin_scan(repository, scan_key, baselines, options \\ [])

  def begin_scan(%Repository{} = repository, scan_key, baselines, options)
      when is_list(baselines) and is_list(options) do
    with :ok <- validate_scan_key(scan_key),
         {:ok, batch_limit} <- batch_limit(options),
         {:ok, baselines} <- normalize_baselines(baselines) do
      fingerprint = baseline_fingerprint(baselines)

      transaction(fn ->
        repository = lock_current_repository!(repository)

        case locked_scan(repository.id, scan_key) do
          nil -> create_scan!(repository, scan_key, fingerprint, baselines, batch_limit)
          scan -> resume_matching_scan!(scan, repository, fingerprint, batch_limit)
        end
      end)
    end
  end

  def begin_scan(_repository, _scan_key, _baselines, _options),
    do: {:error, :invalid_request}

  @spec resume_scan(Repository.t(), String.t()) :: {:ok, Scan.t()} | {:error, atom()}
  def resume_scan(%Repository{} = repository, scan_key) do
    with :ok <- validate_scan_key(scan_key),
         {:ok, repository} <- current_repository(repository) do
      case Repo.get_by(Scan, repository_id: repository.id, scan_key: scan_key) do
        %Scan{repository_generation: generation} = scan
        when generation == repository.generation ->
          {:ok, scan}

        %Scan{} ->
          {:error, :stale_scan}

        nil ->
          {:error, :not_found}
      end
    end
  end

  def resume_scan(_repository, _scan_key), do: {:error, :invalid_request}

  @spec latest_completed_scan(Repository.t()) :: {:ok, Scan.t()} | {:error, atom()}
  def latest_completed_scan(%Repository{} = repository) do
    with {:ok, repository} <- current_repository(repository) do
      Scan
      |> where(
        [scan],
        scan.repository_id == ^repository.id and
          scan.repository_generation == ^repository.generation and
          scan.state in [:complete, :prepared, :published]
      )
      |> order_by([scan], desc: scan.id)
      |> limit(1)
      |> Repo.one()
      |> case do
        %Scan{} = scan -> {:ok, scan}
        nil -> {:error, :not_found}
      end
    end
  end

  def latest_completed_scan(_repository), do: {:error, :invalid_request}

  @doc "Claims a bounded page of pending or expired work under a durable lease."
  @spec claim_work(Scan.t(), String.t(), keyword()) ::
          {:ok, [WorkItem.t()]} | {:error, atom() | {:validation, Changeset.t()}}
  def claim_work(scan, owner, options \\ [])

  def claim_work(%Scan{} = scan, owner, options) when is_list(options) do
    with :ok <- validate_owner(owner),
         {:ok, lease_seconds} <- lease_seconds(options),
         {:ok, requested_limit} <- positive_limit(options, @maximum_batch_limit) do
      transaction(fn ->
        scan = lock_scan_capability!(scan)

        if scan.state != :scanning do
          Repo.rollback(:scan_complete)
        end

        now = DateTime.utc_now(:second)
        expires_at = DateTime.add(now, lease_seconds, :second)
        limit = min(requested_limit, scan.batch_limit)

        WorkItem
        |> where(
          [work],
          work.scan_id == ^scan.id and
            (work.state == :pending or
               (work.state == :processing and work.lease_expires_at <= ^now))
        )
        |> order_by([work], asc: work.id)
        |> limit(^limit)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.all()
        |> Enum.map(fn work ->
          work
          |> WorkItem.claim_changeset(owner, expires_at)
          |> update!()
        end)
      end)
    end
  end

  def claim_work(_scan, _owner, _options), do: {:error, :invalid_request}

  @doc "Atomically records one replay-safe bounded GitCore expansion."
  @spec record_expansion(WorkItem.t(), String.t(), expansion()) ::
          {:ok, %{work_item: WorkItem.t(), scan: Scan.t()}}
          | {:error, atom() | {:validation, Changeset.t()}}
  def record_expansion(%WorkItem{} = capability, owner, expansion) do
    with :ok <- validate_owner(owner) do
      transaction(fn ->
        scan = lock_scan_for_work!(capability)
        normalized = normalize_expansion!(expansion, capability.tree_offset, scan.batch_limit)
        fingerprint = result_fingerprint(normalized)
        work = lock_work_item!(capability)

        if replay?(work, capability, owner, fingerprint) do
          %{work_item: work, scan: scan}
        else
          if scan.state != :scanning, do: Repo.rollback(:scan_complete)
          authorize_expansion!(work, capability, owner)
          validate_resolved_kind!(work.object_kind, normalized.object_kind)
          scan_ref = scan_ref!(scan.id, work.ref_name)

          persist_candidate!(scan, scan_ref, normalized.object_kind, normalized.candidate)
          enqueue_children!(scan, work.ref_name, normalized.children)

          next_state = if is_nil(normalized.next_offset), do: :done, else: :pending
          next_offset = normalized.next_offset || work.tree_offset

          updated_work =
            work
            |> WorkItem.expansion_changeset(%{
              object_kind: normalized.object_kind,
              state: next_state,
              tree_offset: next_offset,
              last_expanded_offset: work.tree_offset,
              last_result_fingerprint: fingerprint,
              last_owner: owner
            })
            |> update!()

          scan = maybe_complete_scan!(scan)
          %{work_item: updated_work, scan: scan}
        end
      end)
    end
  end

  def record_expansion(_work_item, _owner, _expansion), do: {:error, :invalid_request}

  @doc "Lists discovered LFS requirements after traversal completes."
  @spec list_requirements(Scan.t(), keyword()) ::
          {:ok,
           %{
             objects: [%{oid: String.t(), size: non_neg_integer(), first_seen_ref: String.t()}],
             next_cursor: String.t() | nil
           }}
          | {:error, atom()}
  def list_requirements(scan, options \\ [])

  def list_requirements(%Scan{} = scan, options) when is_list(options) do
    with {:ok, scan} <- load_scan_capability(scan),
         :ok <- require_completed(scan),
         {:ok, limit} <- positive_limit(options, @maximum_page_limit),
         {:ok, cursor} <- oid_cursor(options) do
      query =
        Reachability
        |> where([reachability], reachability.scan_id == ^scan.id)
        |> maybe_after_oid(cursor)
        |> group_by([reachability], [reachability.oid_sha256, reachability.size])
        |> order_by([reachability], asc: reachability.oid_sha256)
        |> limit(^(limit + 1))
        |> select([reachability], %{
          oid: reachability.oid_sha256,
          size: reachability.size,
          first_seen_ref: min(reachability.ref_name)
        })

      rows = Repo.all(query)
      {objects, more} = Enum.split(rows, limit)
      next_cursor = if more == [], do: nil, else: List.last(objects).oid
      {:ok, %{objects: objects, next_cursor: next_cursor}}
    end
  end

  def list_requirements(_scan, _options), do: {:error, :invalid_request}

  @doc "Publishes a completed scan as the repository's authoritative LFS reachability."
  @spec publish_scan(Scan.t()) ::
          {:ok, Scan.t()} | {:error, atom() | {:validation, Changeset.t()}}
  def publish_scan(%Scan{} = capability) do
    publish_scan(capability, :replace)
  end

  def publish_scan(_scan), do: {:error, :invalid_request}

  @doc "Makes verified prospective objects available without revoking objects used by live refs."
  @spec prepare_scan(Scan.t()) :: {:ok, Scan.t()} | {:error, term()}
  def prepare_scan(%Scan{} = capability), do: publish_scan(capability, :retain)
  def prepare_scan(_scan), do: {:error, :invalid_request}

  defp publish_scan(capability, mode) do
    transaction(fn ->
      repository = lock_scan_repository!(capability)
      scan = lock_scan_capability!(capability)
      if mode == :replace, do: reject_superseded!(scan)

      case scan.state do
        :published ->
          scan

        state when state in [:complete, :prepared] ->
          now = DateTime.utc_now(:second)
          ensure_requirements_available!(scan)

          if mode == :replace do
            RepositoryObject
            |> where([mapping], mapping.repository_id == ^repository.id)
            |> Repo.update_all(set: [reachable: false, last_reconciled_at: now, updated_at: now])
          end

          publish_ready_objects!(scan, repository.id, now)

          scan
          |> Scan.publication_changeset(
            now,
            if(mode == :replace, do: :published, else: :prepared)
          )
          |> update!()

        :scanning ->
          Repo.rollback(:scan_incomplete)
      end
    end)
  end

  @doc "Returns a bounded page from the latest published reachability snapshot."
  @spec list_current_reachability(Repository.t(), keyword()) ::
          {:ok, [Reachability.t()]} | {:error, atom()}
  def list_current_reachability(repository, options \\ [])

  def list_current_reachability(%Repository{} = repository, options)
      when is_list(options) do
    with {:ok, repository} <- current_repository(repository),
         {:ok, limit} <- positive_limit(options, @maximum_page_limit),
         {:ok, after_id} <- integer_cursor(options) do
      published_scan =
        Scan
        |> where(
          [scan],
          scan.repository_id == ^repository.id and
            scan.repository_generation == ^repository.generation and scan.state == :published
        )
        |> order_by([scan], desc: scan.id)
        |> limit(1)
        |> Repo.one()

      case published_scan do
        nil ->
          {:error, :not_found}

        %Scan{id: scan_id} ->
          rows =
            Reachability
            |> where(
              [reachability],
              reachability.scan_id == ^scan_id and reachability.id > ^after_id
            )
            |> order_by([reachability], asc: reachability.id)
            |> limit(^limit)
            |> Repo.all()

          {:ok, rows}
      end
    end
  end

  def list_current_reachability(_repository, _options), do: {:error, :invalid_request}

  defp create_scan!(repository, scan_key, fingerprint, baselines, batch_limit) do
    scan =
      %Scan{}
      |> Scan.creation_changeset(%{
        repository_id: repository.id,
        repository_generation: repository.generation,
        scan_key: scan_key,
        baseline_fingerprint: fingerprint,
        batch_limit: batch_limit
      })
      |> insert!()

    Enum.each(baselines, fn baseline ->
      %ScanRef{}
      |> ScanRef.changeset(%{
        scan_id: scan.id,
        ref_name: baseline.ref_name,
        ref_kind: baseline.ref_kind,
        target_oid: baseline.oid
      })
      |> insert!()

      %WorkItem{}
      |> WorkItem.creation_changeset(%{
        scan_id: scan.id,
        ref_name: baseline.ref_name,
        object_oid: baseline.oid,
        object_kind: initial_kind(baseline.ref_kind)
      })
      |> insert!()
    end)

    if baselines == [] do
      scan
      |> Scan.completion_changeset(DateTime.utc_now(:second))
      |> update!()
    else
      scan
    end
  end

  defp resume_matching_scan!(scan, repository, fingerprint, batch_limit) do
    cond do
      scan.repository_generation != repository.generation -> Repo.rollback(:stale_scan)
      scan.baseline_fingerprint != fingerprint -> Repo.rollback(:baseline_mismatch)
      scan.batch_limit != batch_limit -> Repo.rollback(:batch_limit_mismatch)
      true -> scan
    end
  end

  defp initial_kind(:branch), do: :commit
  defp initial_kind(:tag), do: :tag_or_commit

  defp normalize_baselines(baselines) do
    baselines
    |> Enum.reduce_while({:ok, []}, fn baseline, {:ok, normalized} ->
      case normalize_baseline(baseline) do
        {:ok, baseline} -> {:cont, {:ok, [baseline | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.sort_by(normalized, & &1.ref_name)

        if duplicate_ref?(normalized) do
          {:error, :duplicate_baseline}
        else
          {:ok, normalized}
        end

      error ->
        error
    end
  end

  defp normalize_baseline(%{ref_name: ref_name, ref_kind: ref_kind, oid: oid})
       when ref_kind in [:branch, :tag] do
    if valid_ref?(ref_name, ref_kind) and is_binary(oid) and Regex.match?(@git_oid_regex, oid) do
      {:ok, %{ref_name: ref_name, ref_kind: ref_kind, oid: oid}}
    else
      {:error, :invalid_baseline}
    end
  end

  defp normalize_baseline(_baseline), do: {:error, :invalid_baseline}

  defp duplicate_ref?(baselines) do
    names = Enum.map(baselines, & &1.ref_name)
    names != Enum.uniq(names)
  end

  defp valid_ref?(ref_name, ref_kind) when is_binary(ref_name) do
    prefix = if ref_kind == :branch, do: "refs/heads/", else: "refs/tags/"

    String.valid?(ref_name) and byte_size(ref_name) <= 1_024 and
      String.starts_with?(ref_name, prefix) and byte_size(ref_name) > byte_size(prefix) and
      not String.contains?(ref_name, ["..", "@{", "\\", " ", "~", "^", ":", "?", "*", "["]) and
      not String.ends_with?(ref_name, ["/", ".", ".lock"]) and
      not String.contains?(ref_name, "//") and
      Enum.all?(String.split(ref_name, "/"), &(not String.starts_with?(&1, ".")))
  end

  defp valid_ref?(_ref_name, _ref_kind), do: false

  defp baseline_fingerprint(baselines) do
    encoded =
      Enum.map_join(baselines, "\n", fn baseline ->
        "#{baseline.ref_kind}\0#{baseline.ref_name}\0#{baseline.oid}"
      end)

    :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
  end

  defp normalize_expansion!(
         %{
           object_kind: object_kind,
           children: children,
           candidate: candidate,
           next_offset: next_offset
         },
         current_offset,
         batch_limit
       )
       when object_kind in [:commit, :tree, :blob, :tag] and is_list(children) do
    if length(children) > min(batch_limit, @maximum_batch_limit) do
      Repo.rollback(:batch_too_large)
    end

    children = normalize_children!(children)
    candidate = normalize_candidate!(candidate, object_kind)

    case next_offset do
      nil -> :ok
      offset when is_integer(offset) and offset > current_offset -> :ok
      _invalid -> Repo.rollback(:invalid_next_offset)
    end

    %{
      object_kind: object_kind,
      children: children,
      candidate: candidate,
      next_offset: next_offset
    }
  end

  defp normalize_expansion!(_expansion, _current_offset, _batch_limit),
    do: Repo.rollback(:invalid_expansion)

  defp normalize_children!(children) do
    {children, seen} =
      Enum.map_reduce(children, %{}, fn
        %{oid: oid, kind: kind}, seen
        when is_binary(oid) and kind in [:commit, :tree, :blob, :tag, :tag_or_commit] ->
          unless Regex.match?(@git_oid_regex, oid), do: Repo.rollback(:invalid_child)

          case Map.fetch(seen, oid) do
            :error -> {%{oid: oid, kind: kind}, Map.put(seen, oid, kind)}
            {:ok, ^kind} -> {nil, seen}
            {:ok, _other_kind} -> Repo.rollback(:inconsistent_child_kind)
          end

        _child, _seen ->
          Repo.rollback(:invalid_child)
      end)

    _ = seen
    Enum.reject(children, &is_nil/1)
  end

  defp normalize_candidate!(nil, _object_kind), do: nil

  defp normalize_candidate!(%{data: data, blob_size: blob_size}, :blob)
       when is_binary(data) and is_integer(blob_size) and blob_size >= 0 and blob_size <= 1_024 do
    if blob_size == byte_size(data) do
      %{data: data, blob_size: blob_size}
    else
      Repo.rollback(:candidate_size_mismatch)
    end
  end

  defp normalize_candidate!(_candidate, _object_kind), do: Repo.rollback(:invalid_candidate)

  defp result_fingerprint(expansion) do
    :crypto.hash(:sha256, :erlang.term_to_binary(expansion, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp replay?(work, capability, owner, fingerprint) do
    work.last_expanded_offset == capability.tree_offset and
      work.last_result_fingerprint == fingerprint and work.last_owner == owner
  end

  defp authorize_expansion!(work, capability, owner) do
    now = DateTime.utc_now(:second)

    valid_capability? =
      work.id == capability.id and work.scan_id == capability.scan_id and
        work.ref_name == capability.ref_name and work.object_oid == capability.object_oid and
        work.tree_offset == capability.tree_offset

    valid_lease? =
      work.state == :processing and work.lease_owner == owner and
        match?(%DateTime{}, work.lease_expires_at) and
        DateTime.compare(work.lease_expires_at, now) == :gt

    unless valid_capability? and valid_lease?, do: Repo.rollback(:stale_work)
  end

  defp validate_resolved_kind!(hint, actual) do
    valid? = hint == actual or (hint == :tag_or_commit and actual in [:tag, :commit])
    unless valid?, do: Repo.rollback(:object_kind_mismatch)
  end

  defp persist_candidate!(_scan, _scan_ref, _object_kind, nil), do: :ok

  defp persist_candidate!(scan, scan_ref, :blob, %{data: data}) do
    case Pointer.parse(data) do
      {:ok, %Pointer{oid: oid, size: size}} ->
        ensure_scan_pointer_size!(scan.id, oid, size)

        %Reachability{}
        |> Reachability.changeset(%{
          scan_id: scan.id,
          ref_name: scan_ref.ref_name,
          ref_kind: scan_ref.ref_kind,
          target_oid: scan_ref.target_oid,
          oid_sha256: oid,
          size: size
        })
        |> insert!(
          on_conflict: :nothing,
          conflict_target: [:scan_id, :ref_name, :oid_sha256]
        )

        :ok

      {:error, :invalid_pointer} ->
        :ok
    end
  end

  defp ensure_scan_pointer_size!(scan_id, oid, size) do
    Reachability
    |> where(
      [reachability],
      reachability.scan_id == ^scan_id and reachability.oid_sha256 == ^oid
    )
    |> select([reachability], reachability.size)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> :ok
      ^size -> :ok
      _other_size -> Repo.rollback(:pointer_size_mismatch)
    end
  end

  defp enqueue_children!(scan, ref_name, children) do
    Enum.each(children, fn child ->
      case Repo.get_by(WorkItem,
             scan_id: scan.id,
             ref_name: ref_name,
             object_oid: child.oid
           ) do
        nil ->
          %WorkItem{}
          |> WorkItem.creation_changeset(%{
            scan_id: scan.id,
            ref_name: ref_name,
            object_oid: child.oid,
            object_kind: child.kind
          })
          |> insert!()

        %WorkItem{object_kind: existing_kind} ->
          unless compatible_hints?(existing_kind, child.kind),
            do: Repo.rollback(:inconsistent_child_kind)
      end
    end)
  end

  defp compatible_hints?(kind, kind), do: true
  defp compatible_hints?(:tag_or_commit, kind) when kind in [:tag, :commit], do: true
  defp compatible_hints?(kind, :tag_or_commit) when kind in [:tag, :commit], do: true
  defp compatible_hints?(_existing, _new), do: false

  defp maybe_complete_scan!(scan) do
    unfinished? =
      WorkItem
      |> where([work], work.scan_id == ^scan.id and work.state in [:pending, :processing])
      |> Repo.exists?()

    if unfinished? do
      scan
    else
      scan
      |> Scan.completion_changeset(DateTime.utc_now(:second))
      |> update!()
    end
  end

  defp publish_ready_objects!(scan, repository_id, now) do
    ready_objects =
      Reachability
      |> join(:inner, [reachability], object in LFSObject,
        on:
          object.oid_sha256 == reachability.oid_sha256 and object.size == reachability.size and
            object.state == :ready
      )
      |> where([reachability, _object], reachability.scan_id == ^scan.id)
      |> group_by([reachability, _object], reachability.oid_sha256)
      |> select([reachability, _object], %{
        repository_id: ^repository_id,
        oid_sha256: reachability.oid_sha256,
        first_seen_ref: min(reachability.ref_name),
        reachable: true,
        last_reconciled_at: ^now,
        inserted_at: ^now,
        updated_at: ^now
      })

    Repo.insert_all(RepositoryObject, ready_objects,
      on_conflict: [set: [reachable: true, last_reconciled_at: now, updated_at: now]],
      conflict_target: [:repository_id, :oid_sha256]
    )
  end

  defp ensure_requirements_available!(scan) do
    missing? =
      Reachability
      |> join(:left, [reachability], object in LFSObject,
        on:
          object.oid_sha256 == reachability.oid_sha256 and object.size == reachability.size and
            object.state == :ready
      )
      |> where(
        [reachability, object],
        reachability.scan_id == ^scan.id and is_nil(object.oid_sha256)
      )
      |> Repo.exists?()

    if missing?, do: Repo.rollback(:requirements_unavailable)
  end

  defp reject_superseded!(scan) do
    newer? =
      Scan
      |> where(
        [candidate],
        candidate.repository_id == ^scan.repository_id and
          candidate.repository_generation == ^scan.repository_generation and
          candidate.id > ^scan.id and candidate.state in [:complete, :published]
      )
      |> Repo.exists?()

    if newer?, do: Repo.rollback(:superseded)
  end

  defp scan_ref!(scan_id, ref_name) do
    case Repo.get_by(ScanRef, scan_id: scan_id, ref_name: ref_name) do
      %ScanRef{} = scan_ref -> scan_ref
      nil -> Repo.rollback(:invalid_work)
    end
  end

  defp lock_current_repository!(%Repository{id: id, generation: generation}) do
    Repository
    |> where(
      [repository],
      repository.id == ^id and repository.generation == ^generation and
        repository.lifecycle in [:ready, :synchronizing] and is_nil(repository.deleted_at)
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %Repository{} = repository -> repository
      nil -> Repo.rollback(:stale_repository)
    end
  end

  defp lock_scan_repository!(%Scan{
         repository_id: repository_id,
         repository_generation: generation
       }) do
    Repository
    |> where(
      [repository],
      repository.id == ^repository_id and repository.generation == ^generation and
        repository.lifecycle in [:ready, :synchronizing] and is_nil(repository.deleted_at)
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %Repository{} = repository -> repository
      nil -> Repo.rollback(:stale_repository)
    end
  end

  defp current_repository(%Repository{id: id, generation: generation})
       when is_integer(id) and is_integer(generation) do
    Repository
    |> where(
      [repository],
      repository.id == ^id and repository.generation == ^generation and
        repository.lifecycle in [:ready, :synchronizing] and is_nil(repository.deleted_at)
    )
    |> Repo.one()
    |> case do
      %Repository{} = repository -> {:ok, repository}
      nil -> {:error, :stale_repository}
    end
  end

  defp current_repository(_repository), do: {:error, :invalid_request}

  defp locked_scan(repository_id, scan_key) do
    Scan
    |> where([scan], scan.repository_id == ^repository_id and scan.scan_key == ^scan_key)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_scan_capability!(%Scan{id: id} = capability) when is_integer(id) do
    Scan
    |> where([scan], scan.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %Scan{} = scan ->
        if same_scan_capability?(scan, capability), do: scan, else: Repo.rollback(:stale_scan)

      nil ->
        Repo.rollback(:not_found)
    end
  end

  defp lock_scan_capability!(_scan), do: Repo.rollback(:invalid_scan)

  defp load_scan_capability(%Scan{id: id} = capability) when is_integer(id) do
    case Repo.get(Scan, id) do
      %Scan{} = scan ->
        if same_scan_capability?(scan, capability), do: {:ok, scan}, else: {:error, :stale_scan}

      nil ->
        {:error, :not_found}
    end
  end

  defp load_scan_capability(_scan), do: {:error, :invalid_scan}

  defp same_scan_capability?(scan, capability) do
    scan.repository_id == capability.repository_id and
      scan.repository_generation == capability.repository_generation and
      scan.scan_key == capability.scan_key and
      scan.baseline_fingerprint == capability.baseline_fingerprint
  end

  defp lock_scan_for_work!(%WorkItem{scan_id: scan_id}) when is_integer(scan_id) do
    Scan
    |> where([scan], scan.id == ^scan_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %Scan{} = scan -> scan
      nil -> Repo.rollback(:invalid_work)
    end
  end

  defp lock_scan_for_work!(_work), do: Repo.rollback(:invalid_work)

  defp lock_work_item!(%WorkItem{id: id}) when is_integer(id) do
    WorkItem
    |> where([work], work.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %WorkItem{} = work -> work
      nil -> Repo.rollback(:invalid_work)
    end
  end

  defp lock_work_item!(_work), do: Repo.rollback(:invalid_work)

  defp require_completed(%Scan{state: state}) when state in [:complete, :prepared, :published],
    do: :ok

  defp require_completed(%Scan{}), do: {:error, :scan_incomplete}

  defp validate_scan_key(scan_key) when is_binary(scan_key) do
    if String.valid?(scan_key) and byte_size(scan_key) in 1..255 and
         scan_key == String.trim(scan_key) and
         not String.contains?(scan_key, <<0>>) do
      :ok
    else
      {:error, :invalid_scan_key}
    end
  end

  defp validate_scan_key(_scan_key), do: {:error, :invalid_scan_key}

  defp validate_owner(owner) when is_binary(owner) do
    if String.valid?(owner) and byte_size(owner) in 1..255 and owner == String.trim(owner) and
         not String.contains?(owner, <<0>>) do
      :ok
    else
      {:error, :invalid_owner}
    end
  end

  defp validate_owner(_owner), do: {:error, :invalid_owner}

  defp batch_limit(options) do
    case Keyword.get(options, :batch_limit, @default_batch_limit) do
      limit when is_integer(limit) and limit in 1..@maximum_batch_limit -> {:ok, limit}
      _invalid -> {:error, :invalid_batch_limit}
    end
  end

  defp lease_seconds(options) do
    case Keyword.get(options, :lease_seconds, @default_lease_seconds) do
      seconds when is_integer(seconds) and seconds in 1..@maximum_lease_seconds -> {:ok, seconds}
      _invalid -> {:error, :invalid_lease}
    end
  end

  defp positive_limit(options, maximum) do
    case Keyword.get(options, :limit, maximum) do
      limit when is_integer(limit) and limit >= 1 and limit <= maximum -> {:ok, limit}
      _invalid -> {:error, :invalid_limit}
    end
  end

  defp oid_cursor(options) do
    case Keyword.get(options, :after_oid) do
      nil ->
        {:ok, nil}

      oid when is_binary(oid) ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, oid),
          do: {:ok, oid},
          else: {:error, :invalid_cursor}

      _invalid ->
        {:error, :invalid_cursor}
    end
  end

  defp integer_cursor(options) do
    case Keyword.get(options, :after_id, 0) do
      cursor when is_integer(cursor) and cursor >= 0 -> {:ok, cursor}
      _invalid -> {:error, :invalid_cursor}
    end
  end

  defp maybe_after_oid(query, nil), do: query

  defp maybe_after_oid(query, oid),
    do: where(query, [reachability], reachability.oid_sha256 > ^oid)

  defp insert!(changeset, options \\ []) do
    case Repo.insert(changeset, options) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback({:validation, changeset})
    end
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback({:validation, changeset})
    end
  end

  defp transaction(function) do
    case Repo.transaction(function) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
