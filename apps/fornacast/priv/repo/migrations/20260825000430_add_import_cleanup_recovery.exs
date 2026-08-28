defmodule Fornacast.Repo.Migrations.AddImportCleanupRecovery do
  use Ecto.Migration

  @disable_ddl_transaction true

  @kind_check "kind in ('remote_quarantine', 'unpublished_shadow', 'replacement_tombstone')"
  @state_check "state in ('cleanup_pending', 'cleanup_blocked', 'cleanup_complete')"
  @identity_check "repository_id > 0 and repository_item_id > 0 and source_lock_version > 0"
  @attempt_check "attempt_count >= 0"
  @version_check "lock_version >= 0"
  @lease_pair_check "(lease_owner is null and lease_expires_at is null) or " <>
                      "(lease_owner is not null and length(trim(lease_owner)) > 0 and lease_expires_at is not null)"
  @effect_order_check "(effect_finished_at is null or " <>
                        "(effect_started_at is not null and effect_started_at <= effect_finished_at))"
  @max_integer 9_223_372_036_854_775_807
  @operation_id_check "operation_id = 'github-import-cleanup:' || kind || ':' || " <>
                        "repository_id || ':' || repository_item_id || ':' || source_lock_version"
  @git_pair_check "(lease_owner is null and lease_expires_at is null) or " <>
                    "(lease_owner is not null and lease_expires_at is not null)"
  @git_terminal_check "state not in ('bookkeeping_complete', 'failed') or " <>
                        "(lease_owner is null and lease_expires_at is null)"
  @merge_terminal_check "state not in ('completed', 'failed') or " <>
                          "(lease_owner is null and lease_expires_at is null)"
  @replacement_keys ~w(version kind storage_root relative_path repository_id repository_generation repository_write_version repository_storage_path repository_deleted_at repository_updated_at item_id item_lock_version attempt_number attempt_decision attempt_fingerprint publication_operation_id publication_marker new_repository_id new_repository_generation publication_audit_id)
  @unpublished_keys ~w(version kind storage_root relative_path repository_id repository_generation repository_write_version repository_storage_path repository_updated_at item_id item_lock_version item_state run_id run_state attempt_number attempt_state attempt_decision attempt_fingerprint publication_evidence predecessor_item_id successor_item_id adopter_item_id)
  @remote_keys ~w(version kind storage_root relative_path repository_id repository_generation repository_storage_path item_id item_lock_version requested_path quarantine_path mode major_device minor_device inode remote_failure_kind)
  @marker_keys ~w(version state attempt_number action hidden_repository_id operation_id request_metadata repository_id owner_user_id slug generation replaced_repository_id run_id published_count_after run_lock_version_after)
  @replacement_decision_keys ~w(action slug replacement_repository_id replacement_owner_id replacement_storage_path replacement_generation replacement_write_version replacement_updated_at replacement_last_pushed_at)

  def up do
    create_cleanup_table()

    if turso?() do
      rebuild_turso_operation_tables()
    else
      add_postgres_operation_checks()
    end
  end

  def down do
    # TODO(upstream): gsmlg-dev/concord#81
    if turso?() do
      raise "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved"
    end

    execute(
      "ALTER TABLE pull_merge_operations DROP CONSTRAINT pull_merge_operations_terminal_lease_check"
    )

    execute(
      "ALTER TABLE pull_merge_operations DROP CONSTRAINT pull_merge_operations_lease_pair_check"
    )

    execute(
      "ALTER TABLE git_write_operations DROP CONSTRAINT git_write_operations_terminal_lease_check"
    )

    execute(
      "ALTER TABLE git_write_operations DROP CONSTRAINT git_write_operations_lease_pair_check"
    )

    drop(table(:github_import_repository_cleanups))
  end

  defp create_cleanup_table do
    create table(:github_import_repository_cleanups) do
      add(
        :repository_id,
        references(:repositories, on_delete: :restrict),
        column_options(
          [null: false],
          :github_import_cleanups_positive_identity_check,
          @identity_check
        )
      )

      add(
        :repository_item_id,
        references(:github_import_repository_items, on_delete: :restrict),
        null: false
      )

      add(:source_lock_version, :bigint, null: false)

      add(
        :kind,
        :string,
        column_options([null: false], :github_import_cleanups_kind_check, @kind_check)
      )

      add(
        :state,
        :string,
        column_options(
          [null: false, default: "cleanup_pending"],
          :github_import_cleanups_state_check,
          @state_check
        )
      )

      add(
        :operation_id,
        :string,
        column_options(
          [null: false],
          :github_import_cleanups_operation_id_check,
          @operation_id_check
        )
      )

      add(
        :evidence,
        :map,
        column_options(
          [null: false],
          :github_import_cleanups_evidence_check,
          evidence_check()
        )
      )

      add(:eligible_at, :utc_datetime, null: false)

      add(
        :next_attempt_at,
        :utc_datetime,
        column_options([], :github_import_cleanups_lifecycle_check, lifecycle_check())
      )

      add(
        :attempt_count,
        :integer,
        column_options(
          [null: false, default: 0],
          :github_import_cleanups_attempt_count_check,
          @attempt_check
        )
      )

      add(:last_error, :string)
      add(:effect_started_at, :utc_datetime)

      add(
        :effect_finished_at,
        :utc_datetime,
        column_options([], :github_import_cleanups_effect_order_check, @effect_order_check)
      )

      add(:completed_at, :utc_datetime)

      add(
        :lease_owner,
        :string,
        column_options([], :github_import_cleanups_lease_pair_check, @lease_pair_check)
      )

      add(:lease_expires_at, :utc_datetime)

      add(
        :lock_version,
        :integer,
        column_options(
          [null: false, default: 0],
          :github_import_cleanups_lock_version_check,
          @version_check
        )
      )

      timestamps(type: :utc_datetime)
    end

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_kind_check,
      @kind_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_state_check,
      @state_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_positive_identity_check,
      @identity_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_attempt_count_check,
      @attempt_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_lock_version_check,
      @version_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_lease_pair_check,
      @lease_pair_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_effect_order_check,
      @effect_order_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_lifecycle_check,
      lifecycle_check()
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_operation_id_check,
      @operation_id_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_evidence_check,
      evidence_check()
    )

    create(
      unique_index(:github_import_repository_cleanups, [:operation_id],
        name: :github_import_repository_cleanups_operation_id_index
      )
    )

    create(
      unique_index(
        :github_import_repository_cleanups,
        [:repository_item_id, :kind, :source_lock_version],
        name: :github_import_cleanups_item_kind_version_index
      )
    )

    create(
      index(
        :github_import_repository_cleanups,
        [:state, :next_attempt_at, :eligible_at, :id],
        name: :github_import_repository_cleanups_recovery_index
      )
    )
  end

  defp evidence_check do
    if turso?() do
      "json_valid(evidence) and json_type(evidence) = 'object' and " <>
        "json_extract(evidence, '$.version') = 1 and " <>
        "json_extract(evidence, '$.kind') = kind and " <>
        "json_extract(evidence, '$.repository_id') = repository_id and " <>
        "json_extract(evidence, '$.item_id') = repository_item_id and " <>
        "json_extract(evidence, '$.item_lock_version') = source_lock_version and " <>
        exact_kind_keys_check(:turso) <>
        " and " <> base_kind_check(:turso) <> " and " <> anchor_check(:turso)
    else
      "jsonb_typeof(evidence) = 'object' and evidence @> jsonb_build_object(" <>
        "'version', 1, 'kind', kind, 'repository_id', repository_id, " <>
        "'item_id', repository_item_id, 'item_lock_version', source_lock_version) and " <>
        exact_kind_keys_check(:postgres) <>
        " and " <> base_kind_check(:postgres) <> " and " <> anchor_check(:postgres)
    end
  end

  defp base_kind_check(adapter) do
    "((kind = 'remote_quarantine' and #{remote_evidence_check(adapter)}) or " <>
      "(kind = 'unpublished_shadow' and #{unpublished_evidence_check(adapter)}) or " <>
      "(kind = 'replacement_tombstone' and #{replacement_evidence_check(adapter)}))"
  end

  defp remote_evidence_check(adapter) do
    root = json_text(adapter, "storage_root")
    relative = json_text(adapter, "relative_path")
    repository_path = json_text(adapter, "repository_storage_path")
    requested = json_text(adapter, "requested_path")
    quarantine = json_text(adapter, "quarantine_path")

    [
      canonical_absolute_check(adapter, "storage_root"),
      canonical_relative_check(adapter, "relative_path", 4_096),
      repository_path_check(adapter),
      canonical_absolute_check(adapter, "requested_path"),
      canonical_absolute_check(adapter, "quarantine_path"),
      positive_json_integer_check(adapter, "repository_generation"),
      exact_json_integer_check(adapter, "mode", 448),
      nonnegative_json_integer_check(adapter, "major_device"),
      nonnegative_json_integer_check(adapter, "minor_device"),
      positive_json_integer_check(adapter, "inode"),
      classified_string_check(adapter, "remote_failure_kind"),
      "#{requested} = #{root} || '/' || #{repository_path}",
      "#{quarantine} = #{root} || '/' || #{relative}",
      cleanup_leaf_check(adapter),
      same_relative_parent_check(adapter)
    ]
    |> Enum.join(" and ")
  end

  defp unpublished_evidence_check(adapter) do
    [
      canonical_absolute_check(adapter, "storage_root"),
      canonical_relative_check(adapter, "relative_path", 1_024),
      repository_path_check(adapter),
      "#{json_text(adapter, "relative_path")} = #{json_text(adapter, "repository_storage_path")}",
      positive_json_integer_check(adapter, "repository_generation"),
      nonnegative_json_integer_check(adapter, "repository_write_version"),
      utc_timestamp_check(adapter, "repository_updated_at"),
      enum_string_check(adapter, "item_state", ~w(completed skipped canceled failed published)),
      positive_json_integer_check(adapter, "run_id"),
      enum_string_check(
        adapter,
        "run_state",
        ~w(completed completed_with_warnings canceled failed)
      ),
      positive_json_integer_check(adapter, "attempt_number"),
      enum_string_check(
        adapter,
        "attempt_state",
        ~w(completed failed canceled destination_changed)
      ),
      decision_check(adapter),
      lowercase_hex_check(adapter, "attempt_fingerprint"),
      empty_object_check(adapter, "publication_evidence"),
      optional_positive_json_integer_check(adapter, "predecessor_item_id"),
      optional_positive_json_integer_check(adapter, "successor_item_id"),
      optional_positive_json_integer_check(adapter, "adopter_item_id")
    ]
    |> Enum.join(" and ")
  end

  defp replacement_evidence_check(adapter) do
    marker = marker_check(adapter)
    decision = replacement_decision_check(adapter)
    old_id = json_text(adapter, "repository_id")
    old_generation = json_text(adapter, "repository_generation")
    old_generation_number = json_number(adapter, "repository_generation")
    old_write_version = json_text(adapter, "repository_write_version")
    old_path = json_text(adapter, "repository_storage_path")
    old_updated_at = json_text(adapter, "repository_updated_at")
    item_id = json_text(adapter, "item_id")
    attempt_number = json_text(adapter, "attempt_number")
    publication_operation = json_text(adapter, "publication_operation_id")
    new_id = json_text(adapter, "new_repository_id")
    new_generation = json_text(adapter, "new_repository_generation")
    marker_value = fn key -> nested_text(adapter, "publication_marker", key) end
    decision_value = fn key -> nested_text(adapter, "attempt_decision", key) end

    [
      canonical_absolute_check(adapter, "storage_root"),
      canonical_relative_check(adapter, "relative_path", 1_024),
      repository_path_check(adapter),
      "#{json_text(adapter, "relative_path")} = #{old_path}",
      positive_json_integer_check(adapter, "repository_generation"),
      nonnegative_json_integer_check(adapter, "repository_write_version"),
      utc_timestamp_check(adapter, "repository_deleted_at"),
      utc_timestamp_check(adapter, "repository_updated_at"),
      "#{json_text(adapter, "repository_deleted_at")} <= #{old_updated_at}",
      positive_json_integer_check(adapter, "attempt_number"),
      decision,
      lowercase_hex_check(adapter, "attempt_fingerprint"),
      nonempty_string_check(adapter, "publication_operation_id", 255),
      marker,
      positive_json_integer_check(adapter, "new_repository_id"),
      positive_json_integer_check(adapter, "new_repository_generation"),
      positive_json_integer_check(adapter, "publication_audit_id"),
      "#{marker_value.("action")} = 'replace'",
      "#{decision_value.("action")} = 'replace'",
      "#{marker_value.("attempt_number")} = #{attempt_number}",
      "#{publication_operation} = 'github-import-publication-' || #{item_id} || '-' || #{attempt_number}",
      "#{marker_value.("operation_id")} = #{publication_operation}",
      "#{marker_value.("repository_id")} = #{marker_value.("hidden_repository_id")}",
      "#{marker_value.("repository_id")} = #{new_id}",
      "#{marker_value.("replaced_repository_id")} = #{old_id}",
      "#{marker_value.("generation")} = #{new_generation}",
      "#{marker_value.("slug")} = #{decision_value.("slug")}",
      "#{marker_value.("owner_user_id")} = #{decision_value.("replacement_owner_id")}",
      "#{decision_value.("replacement_repository_id")} = #{old_id}",
      "#{decision_value.("replacement_generation")} = #{old_generation}",
      "#{decision_value.("replacement_write_version")} = #{old_write_version}",
      "#{decision_value.("replacement_storage_path")} = #{old_path}",
      "#{decision_value.("replacement_updated_at")} = #{old_updated_at}",
      "#{nested_number(adapter, "publication_marker", "generation")} = #{old_generation_number} + 1",
      "#{new_id} != #{old_id}"
    ]
    |> Enum.join(" and ")
  end

  defp marker_check(adapter) do
    checks =
      [
        exact_nested_integer_check(adapter, "publication_marker", "version", 1),
        nested_exact_string_check(adapter, "publication_marker", "state", "committed"),
        nested_positive_integer_check(adapter, "publication_marker", "attempt_number"),
        nested_enum_string_check(
          adapter,
          "publication_marker",
          "action",
          ~w(create rename replace)
        ),
        nested_positive_integer_check(adapter, "publication_marker", "hidden_repository_id"),
        nested_nonempty_string_check(adapter, "publication_marker", "operation_id", 255),
        nested_object_check(adapter, "publication_marker", "request_metadata"),
        nested_positive_integer_check(adapter, "publication_marker", "repository_id"),
        nested_positive_integer_check(adapter, "publication_marker", "owner_user_id"),
        nested_canonical_slug_check(adapter, "publication_marker", "slug"),
        nested_positive_integer_check(adapter, "publication_marker", "generation"),
        nested_positive_integer_check(adapter, "publication_marker", "replaced_repository_id"),
        nested_positive_integer_check(adapter, "publication_marker", "run_id"),
        nested_nonnegative_integer_check(adapter, "publication_marker", "published_count_after"),
        nested_positive_integer_check(adapter, "publication_marker", "run_lock_version_after")
      ]
      |> Enum.join(" and ")

    exact_nested_keys_check(adapter, "publication_marker", @marker_keys) <>
      " and " <> checks
  end

  defp decision_check(adapter) do
    action = nested_text(adapter, "attempt_decision", "action")

    ("(#{exact_nested_keys_check(adapter, "attempt_decision", ["action"])} and #{action} = 'skip') or " <>
       "(#{exact_nested_keys_check(adapter, "attempt_decision", ~w(action slug))} and " <>
       "#{action} in ('create', 'rename') and #{nested_canonical_slug_check(adapter, "attempt_decision", "slug")}) or " <>
       "(#{replacement_decision_check(adapter)})")
    |> then(&"(#{&1})")
  end

  defp replacement_decision_check(adapter) do
    checks =
      [
        nested_exact_string_check(adapter, "attempt_decision", "action", "replace"),
        nested_canonical_slug_check(adapter, "attempt_decision", "slug"),
        nested_positive_integer_check(adapter, "attempt_decision", "replacement_repository_id"),
        nested_positive_integer_check(adapter, "attempt_decision", "replacement_owner_id"),
        nested_repository_path_check(adapter, "attempt_decision", "replacement_storage_path"),
        nested_positive_integer_check(adapter, "attempt_decision", "replacement_generation"),
        nested_nonnegative_integer_check(
          adapter,
          "attempt_decision",
          "replacement_write_version"
        ),
        nested_utc_timestamp_check(adapter, "attempt_decision", "replacement_updated_at"),
        nested_optional_utc_timestamp_check(
          adapter,
          "attempt_decision",
          "replacement_last_pushed_at"
        )
      ]
      |> Enum.join(" and ")

    exact_nested_keys_check(adapter, "attempt_decision", @replacement_decision_keys) <>
      " and " <> checks
  end

  defp json_text(:turso, key), do: "json_extract(evidence, '$.#{key}')"
  defp json_text(:postgres, key), do: "(evidence->>'#{key}')"

  defp json_type(:turso, key), do: "json_type(evidence, '$.#{key}')"
  defp json_type(:postgres, key), do: "jsonb_typeof(evidence->'#{key}')"

  defp json_number(:turso, key), do: json_text(:turso, key)
  defp json_number(:postgres, key), do: "(#{json_text(:postgres, key)})::numeric"

  defp nested_text(:turso, object, key),
    do: "json_extract(evidence, '$.#{object}.#{key}')"

  defp nested_text(:postgres, object, key), do: "(evidence #>> '{#{object},#{key}}')"

  defp nested_type(:turso, object, key),
    do: "json_type(evidence, '$.#{object}.#{key}')"

  defp nested_type(:postgres, object, key),
    do: "jsonb_typeof(evidence #> '{#{object},#{key}}')"

  defp nested_number(:turso, object, key), do: nested_text(:turso, object, key)

  defp nested_number(:postgres, object, key),
    do: "(#{nested_text(:postgres, object, key)})::numeric"

  defp canonical_absolute_check(adapter, key) do
    value = json_text(adapter, key)

    base =
      "#{json_type(adapter, key)} = #{string_type(adapter)} and " <>
        byte_length_check(adapter, value, 2, 4_096) <>
        " and #{value} != '/' and #{first_character(adapter, value)} = '/' and " <>
        "#{last_character(adapter, value)} != '/' and " <>
        "#{contains(adapter, value, "//")} = false and " <>
        "#{contains(adapter, value, "\\")} = false and " <>
        "#{contains(adapter, value, "/./")} = false and " <>
        "#{contains(adapter, value, "/../")} = false and " <>
        "#{value} not like '%/.' and #{value} not like '%/..'"

    base <> nul_free_check(adapter, value)
  end

  defp canonical_relative_check(adapter, key, maximum) do
    value = json_text(adapter, key)
    canonical_relative_expression(adapter, json_type(adapter, key), value, maximum)
  end

  defp canonical_relative_expression(adapter, type, value, maximum) do
    type <>
      " = " <>
      string_type(adapter) <>
      " and " <>
      byte_length_check(adapter, value, 1, maximum) <>
      " and #{first_character(adapter, value)} != '/' and " <>
      "#{last_character(adapter, value)} != '/' and " <>
      "#{contains(adapter, value, "//")} = false and " <>
      "#{contains(adapter, value, "\\")} = false and " <>
      "#{contains(adapter, value, "/./")} = false and " <>
      "#{contains(adapter, value, "/../")} = false and " <>
      "#{value} not in ('.', '..') and #{value} not like './%' and " <>
      "#{value} not like '../%' and #{value} not like '%/.' and #{value} not like '%/..' and " <>
      drive_prefix_check(adapter, value) <>
      nul_free_check(adapter, value) <> segment_count_check(adapter, value)
  end

  defp repository_path_check(adapter) do
    canonical_relative_check(adapter, "repository_storage_path", 1_024) <>
      " and #{json_text(adapter, "repository_storage_path")} like '%.git'"
  end

  defp nested_repository_path_check(adapter, object, key) do
    canonical_relative_expression(
      adapter,
      nested_type(adapter, object, key),
      nested_text(adapter, object, key),
      1_024
    ) <> " and #{nested_text(adapter, object, key)} like '%.git'"
  end

  defp cleanup_leaf_check(:turso) do
    value = json_text(:turso, "relative_path")
    leaf = "substr(#{value}, -65)"

    "length(cast(#{leaf} as blob)) = 65 and " <>
      "substr(#{leaf}, 1, 22) = '.fornacast-cleanup-v1-' and " <>
      "length(cast(substr(#{leaf}, 23) as blob)) = 43 and " <>
      "substr(#{leaf}, 23) not glob '*[^A-Za-z0-9_-]*'"
  end

  defp cleanup_leaf_check(:postgres) do
    value = json_text(:postgres, "relative_path")
    "regexp_replace(#{value}, '^.*/', '') ~ '^\\.fornacast-cleanup-v1-[A-Za-z0-9_-]{43}$'"
  end

  defp same_relative_parent_check(:turso) do
    relative = json_text(:turso, "relative_path")
    repository = json_text(:turso, "repository_storage_path")
    prefix_length = "length(#{relative}) - 65"

    "substr(#{repository}, 1, #{prefix_length}) = substr(#{relative}, 1, #{prefix_length}) and " <>
      "instr(substr(#{repository}, #{prefix_length} + 1), '/') = 0"
  end

  defp same_relative_parent_check(:postgres) do
    relative = json_text(:postgres, "relative_path")
    repository = json_text(:postgres, "repository_storage_path")
    "regexp_replace(#{relative}, '[^/]+$', '') = regexp_replace(#{repository}, '[^/]+$', '')"
  end

  defp positive_json_integer_check(adapter, key),
    do: json_integer_check(adapter, json_type(adapter, key), json_text(adapter, key), :positive)

  defp nonnegative_json_integer_check(adapter, key),
    do:
      json_integer_check(adapter, json_type(adapter, key), json_text(adapter, key), :nonnegative)

  defp exact_json_integer_check(adapter, key, expected),
    do:
      json_integer_check(
        adapter,
        json_type(adapter, key),
        json_text(adapter, key),
        {:exact, expected}
      )

  defp optional_positive_json_integer_check(:turso, key) do
    type = json_type(:turso, key)
    value = json_text(:turso, key)
    "(#{type} = 'null' or (#{type} = 'integer' and #{value} > 0))"
  end

  defp optional_positive_json_integer_check(:postgres, key) do
    type = json_type(:postgres, key)

    "(#{type} = 'null' or #{json_integer_check(:postgres, type, json_text(:postgres, key), :positive)})"
  end

  defp nested_positive_integer_check(adapter, object, key),
    do:
      json_integer_check(
        adapter,
        nested_type(adapter, object, key),
        nested_text(adapter, object, key),
        :positive
      )

  defp nested_nonnegative_integer_check(adapter, object, key),
    do:
      json_integer_check(
        adapter,
        nested_type(adapter, object, key),
        nested_text(adapter, object, key),
        :nonnegative
      )

  defp exact_nested_integer_check(adapter, object, key, expected),
    do:
      json_integer_check(
        adapter,
        nested_type(adapter, object, key),
        nested_text(adapter, object, key),
        {:exact, expected}
      )

  defp json_integer_check(:turso, type, value, :positive),
    do: "#{type} = 'integer' and #{value} > 0"

  defp json_integer_check(:turso, type, value, :nonnegative),
    do: "#{type} = 'integer' and #{value} >= 0"

  defp json_integer_check(:turso, type, value, {:exact, expected}),
    do: "#{type} = 'integer' and #{value} = #{expected}"

  defp json_integer_check(:postgres, type, value, comparison) do
    predicate =
      case comparison do
        :positive -> "(#{value})::numeric > 0"
        :nonnegative -> "(#{value})::numeric >= 0"
        {:exact, expected} -> "(#{value})::numeric = #{expected}"
      end

    "case when #{type} = 'number' and #{value} ~ '^-?[0-9]+$' " <>
      "then #{predicate} else false end"
  end

  defp enum_string_check(adapter, key, values) do
    encoded = Enum.map_join(values, ", ", &"'#{&1}'")

    "#{json_type(adapter, key)} = #{string_type(adapter)} and #{json_text(adapter, key)} in (#{encoded})"
  end

  defp nested_enum_string_check(adapter, object, key, values) do
    encoded = Enum.map_join(values, ", ", &"'#{&1}'")

    "#{nested_type(adapter, object, key)} = #{string_type(adapter)} and " <>
      "#{nested_text(adapter, object, key)} in (#{encoded})"
  end

  defp nested_exact_string_check(adapter, object, key, expected) do
    "#{nested_type(adapter, object, key)} = #{string_type(adapter)} and " <>
      "#{nested_text(adapter, object, key)} = '#{expected}'"
  end

  defp nonempty_string_check(adapter, key, maximum) do
    value = json_text(adapter, key)

    "#{json_type(adapter, key)} = #{string_type(adapter)} and " <>
      byte_length_check(adapter, value, 1, maximum)
  end

  defp nested_nonempty_string_check(adapter, object, key, maximum) do
    value = nested_text(adapter, object, key)

    "#{nested_type(adapter, object, key)} = #{string_type(adapter)} and " <>
      byte_length_check(adapter, value, 1, maximum)
  end

  defp classified_string_check(:turso, key) do
    value = json_text(:turso, key)

    nonempty_string_check(:turso, key, 120) <>
      " and #{value} not glob '*[^a-z0-9_]*'"
  end

  defp classified_string_check(:postgres, key) do
    value = json_text(:postgres, key)
    nonempty_string_check(:postgres, key, 120) <> " and #{value} ~ '^[a-z0-9_]+$'"
  end

  defp lowercase_hex_check(:turso, key) do
    value = json_text(:turso, key)

    "#{json_type(:turso, key)} = 'text' and length(cast(#{value} as blob)) = 64 and " <>
      "#{value} not glob '*[^0-9a-f]*'"
  end

  defp lowercase_hex_check(:postgres, key) do
    value = json_text(:postgres, key)
    "#{json_type(:postgres, key)} = 'string' and #{value} ~ '^[0-9a-f]{64}$'"
  end

  defp utc_timestamp_check(:turso, key) do
    value = json_text(:turso, key)

    "#{json_type(:turso, key)} = 'text' and " <>
      "coalesce(strftime('%Y-%m-%dT%H:%M:%SZ', #{value}) = #{value}, 0)"
  end

  defp utc_timestamp_check(:postgres, key) do
    value =
      if String.contains?(key, "."),
        do: nested_path_text(:postgres, key),
        else: json_text(:postgres, key)

    type =
      if String.contains?(key, "."),
        do: nested_path_type(:postgres, key),
        else: json_type(:postgres, key)

    "#{type} = 'string' and #{value} ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'"
  end

  defp nested_utc_timestamp_check(:turso, object, key) do
    value = nested_text(:turso, object, key)

    "#{nested_type(:turso, object, key)} = 'text' and " <>
      "coalesce(strftime('%Y-%m-%dT%H:%M:%SZ', #{value}) = #{value}, 0)"
  end

  defp nested_utc_timestamp_check(:postgres, object, key),
    do: utc_timestamp_check(:postgres, "#{object}.#{key}")

  defp nested_optional_utc_timestamp_check(:turso, object, key) do
    type = nested_type(:turso, object, key)
    "(#{type} = 'null' or (#{nested_utc_timestamp_check(:turso, object, key)}))"
  end

  defp nested_optional_utc_timestamp_check(:postgres, object, key) do
    type = nested_type(:postgres, object, key)
    "(#{type} = 'null' or (#{nested_utc_timestamp_check(:postgres, object, key)}))"
  end

  defp empty_object_check(:turso, key),
    do: "#{json_type(:turso, key)} = 'object' and json_extract(evidence, '$.#{key}') = '{}'"

  defp empty_object_check(:postgres, key),
    do: "#{json_type(:postgres, key)} = 'object' and evidence->'#{key}' = '{}'::jsonb"

  defp exact_nested_keys_check(:turso, object, keys) do
    required =
      Enum.map_join(keys, " and ", &"json_type(evidence, '$.#{object}.#{&1}') is not null")

    removals = Enum.map_join(keys, ", ", &"'$.#{&1}'")

    "json_type(evidence, '$.#{object}') = 'object' and #{required} and " <>
      "json_remove(json_extract(evidence, '$.#{object}'), #{removals}) = '{}'"
  end

  defp exact_nested_keys_check(:postgres, object, keys) do
    encoded = Enum.map_join(keys, ", ", &"'#{&1}'")
    expression = "(evidence->'#{object}')"

    "jsonb_typeof(#{expression}) = 'object' and #{expression} ?& array[#{encoded}] and " <>
      "(#{expression} - array[#{encoded}]::text[]) = '{}'::jsonb"
  end

  defp nested_object_check(adapter, object, key),
    do: "#{nested_type(adapter, object, key)} = #{object_type(adapter)}"

  defp nested_canonical_slug_check(:turso, object, key) do
    value = nested_text(:turso, object, key)

    "#{nested_type(:turso, object, key)} = 'text' and " <>
      byte_length_check(:turso, value, 1, 63) <>
      " and #{value} not glob '*[^a-z0-9._-]*' and #{value} glob '[a-z0-9]*' and " <>
      "#{value} not in ('.', '..') and #{value} not like '%.' and #{value} not like '%.git'"
  end

  defp nested_canonical_slug_check(:postgres, object, key) do
    value = nested_text(:postgres, object, key)

    "#{nested_type(:postgres, object, key)} = 'string' and " <>
      "#{value} ~ '^[a-z0-9][a-z0-9._-]{0,62}$' and " <>
      "#{value} not in ('.', '..') and #{value} not like '%.' and #{value} not like '%.git'"
  end

  defp nested_path_text(:postgres, path) do
    [object, key] = String.split(path, ".", parts: 2)
    nested_text(:postgres, object, key)
  end

  defp nested_path_type(:postgres, path) do
    [object, key] = String.split(path, ".", parts: 2)
    nested_type(:postgres, object, key)
  end

  defp string_type(:turso), do: "'text'"
  defp string_type(:postgres), do: "'string'"
  defp object_type(:turso), do: "'object'"
  defp object_type(:postgres), do: "'object'"

  defp byte_length_check(:turso, value, minimum, maximum),
    do: "length(cast(#{value} as blob)) between #{minimum} and #{maximum}"

  defp byte_length_check(:postgres, value, minimum, maximum),
    do: "octet_length(#{value}) between #{minimum} and #{maximum}"

  defp first_character(:turso, value), do: "substr(#{value}, 1, 1)"
  defp first_character(:postgres, value), do: "left(#{value}, 1)"
  defp last_character(:turso, value), do: "substr(#{value}, -1)"
  defp last_character(:postgres, value), do: "right(#{value}, 1)"

  defp contains(:turso, value, needle), do: "(instr(#{value}, '#{escape_sql(needle)}') > 0)"
  defp contains(:postgres, value, needle), do: "(strpos(#{value}, '#{escape_sql(needle)}') > 0)"

  defp nul_free_check(:turso, value),
    do: " and instr(cast(#{value} as blob), x'00') = 0"

  defp nul_free_check(:postgres, _value), do: ""

  defp drive_prefix_check(:turso, value), do: "#{value} not glob '[A-Za-z]:*'"
  defp drive_prefix_check(:postgres, value), do: "#{value} !~ '^[A-Za-z]:'"

  defp segment_count_check(:turso, value),
    do: " and length(#{value}) - length(replace(#{value}, '/', '')) <= 127"

  defp segment_count_check(:postgres, value),
    do: " and length(#{value}) - length(replace(#{value}, '/', '')) <= 127"

  defp escape_sql(value), do: String.replace(value, "'", "''")

  defp anchor_check(:turso) do
    root = "json_type(evidence, '$.root_identity') is not null"
    target = "json_type(evidence, '$.anchored_identity') is not null"
    absence = "json_type(evidence, '$.anchored_absence') is not null"

    "((effect_started_at is null and not (#{root}) and not (#{target}) and not (#{absence})) or " <>
      "(effect_started_at is not null and (((#{root}) and (#{target}) and not (#{absence}) and " <>
      identity_check(:turso, "$.root_identity") <>
      " and " <>
      identity_check(:turso, "$.anchored_identity") <>
      ") or " <>
      "(not (#{root}) and not (#{target}) and (#{absence}) and effect_finished_at is not null and " <>
      absence_check(:turso) <> "))))"
  end

  defp anchor_check(:postgres) do
    root = "evidence ? 'root_identity'"
    target = "evidence ? 'anchored_identity'"
    absence = "evidence ? 'anchored_absence'"

    "((effect_started_at is null and not (#{root}) and not (#{target}) and not (#{absence})) or " <>
      "(effect_started_at is not null and (((#{root}) and (#{target}) and not (#{absence}) and " <>
      identity_check(:postgres, "root_identity") <>
      " and " <>
      identity_check(:postgres, "anchored_identity") <>
      ") or " <>
      "(not (#{root}) and not (#{target}) and (#{absence}) and effect_finished_at is not null and " <>
      absence_check(:postgres) <> "))))"
  end

  defp exact_kind_keys_check(adapter) do
    [
      {"replacement_tombstone", @replacement_keys},
      {"unpublished_shadow", @unpublished_keys},
      {"remote_quarantine", @remote_keys}
    ]
    |> Enum.map_join(" or ", fn {kind, keys} ->
      all_keys = keys ++ ~w(root_identity anchored_identity anchored_absence)

      required =
        case adapter do
          :turso ->
            Enum.map_join(keys, " and ", &"json_type(evidence, '$.#{&1}') is not null")

          :postgres ->
            encoded = Enum.map_join(keys, ", ", &"'#{&1}'")
            "evidence ?& array[#{encoded}]"
        end

      no_unknown =
        case adapter do
          :turso ->
            paths = Enum.map_join(all_keys, ", ", &"'$.#{&1}'")
            "json_remove(evidence, #{paths}) = '{}'"

          :postgres ->
            encoded = Enum.map_join(all_keys, ", ", &"'#{&1}'")
            "(evidence - array[#{encoded}]::text[]) = '{}'::jsonb"
        end

      "(kind = '#{kind}' and #{required} and #{no_unknown})"
    end)
    |> then(&"(#{&1})")
  end

  defp identity_check(:turso, path) do
    "json_type(evidence, '#{path}') = 'object' and " <>
      "json_type(evidence, '#{path}.mode') = 'integer' and json_extract(evidence, '#{path}.mode') between 0 and #{@max_integer} and " <>
      "json_type(evidence, '#{path}.major_device') = 'integer' and json_extract(evidence, '#{path}.major_device') between 0 and #{@max_integer} and " <>
      "json_type(evidence, '#{path}.minor_device') = 'integer' and json_extract(evidence, '#{path}.minor_device') between 0 and #{@max_integer} and " <>
      "json_type(evidence, '#{path}.inode') = 'integer' and json_extract(evidence, '#{path}.inode') between 1 and #{@max_integer} and " <>
      "json_remove(json_extract(evidence, '#{path}'), '$.mode', '$.major_device', '$.minor_device', '$.inode') = '{}'"
  end

  defp identity_check(:postgres, path) do
    expression = "(evidence #> '{#{path}}')"

    "jsonb_typeof(#{expression}) = 'object' and " <>
      pg_identity_integer_check(path, "mode", 0) <>
      " and " <>
      pg_identity_integer_check(path, "major_device", 0) <>
      " and " <>
      pg_identity_integer_check(path, "minor_device", 0) <>
      " and " <>
      pg_identity_integer_check(path, "inode", 1) <>
      " and " <>
      "(#{expression} - array['mode','major_device','minor_device','inode']::text[]) = '{}'::jsonb"
  end

  defp pg_identity_integer_check(path, field, minimum) do
    type = "jsonb_typeof(evidence #> '{#{path},#{field}}')"
    value = "evidence #>> '{#{path},#{field}}'"

    "case when #{type} = 'number' and #{value} ~ '^-?[0-9]+$' " <>
      "then (#{value})::numeric between #{minimum} and #{@max_integer} else false end"
  end

  defp lifecycle_check do
    "(" <>
      "state = 'cleanup_pending' and next_attempt_at is not null and completed_at is null" <>
      ") or (" <>
      "state = 'cleanup_blocked' and #{classified_last_error_check()} and " <>
      "lease_owner is null and lease_expires_at is null and next_attempt_at is null and completed_at is null" <>
      ") or (" <>
      "state = 'cleanup_complete' and lease_owner is null and lease_expires_at is null and " <>
      "next_attempt_at is null and last_error is null and effect_started_at is not null and " <>
      "effect_finished_at is not null and completed_at is not null and " <>
      "effect_started_at <= effect_finished_at and effect_finished_at <= completed_at" <>
      ")"
  end

  defp classified_last_error_check do
    aliases =
      ~w(token password pat github_pat access_token authorization credential credential_envelope credential_envelopes ciphertext nonce tag key_id raw_body request_body response_body storage_path staged_storage_path replacement_storage_path)

    prefixes = ~w(github_pat_ ghp_ gho_ ghu_ ghs_ ghr_)
    position = if turso?(), do: "instr", else: "strpos"

    common =
      "last_error is not null and length(trim(last_error)) between 1 and 120 and " <>
        "lower(trim(last_error)) not in (#{Enum.map_join(aliases, ", ", &"'#{&1}'")}) and " <>
        Enum.map_join(prefixes, " and ", &"#{position}(lower(last_error), '#{&1}') = 0") <>
        " and #{position}(lower(last_error), 'bearer ') = 0 and " <>
        "#{position}(lower(last_error), 'file:///') = 0 and " <>
        "substr(last_error, 1, 1) not in ('/', '\\')"

    if turso?() do
      controls =
        Enum.map_join(
          [0 | Enum.to_list(1..31)] ++ [127],
          " and ",
          &"instr(last_error, char(#{&1})) = 0"
        )

      common <>
        " and #{controls} and last_error not glob '*[A-Za-z]:[/\\]*' and " <>
        "instr(last_error, '\\\\') = 0"
    else
      common <>
        " and last_error !~ '[[:cntrl:]]' and " <>
        "last_error !~* '(^|[[:space:]\"''(<\\[,{;=])[a-z]:[\\\\/]' and " <>
        "strpos(last_error, '\\\\') = 0"
    end
  end

  defp absence_check(:turso) do
    path = "$.anchored_absence"

    "json_type(evidence, '#{path}') = 'object' and json_extract(evidence, '#{path}.version') = 1 and " <>
      "json_type(evidence, '#{path}.observed_at') = 'text' and " <>
      identity_check(:turso, "#{path}.root_identity") <>
      " and " <>
      utc_timestamp_check(:turso, "#{path}.observed_at") <>
      " and coalesce(strftime('%s', json_extract(evidence, '#{path}.observed_at')) >= " <>
      "strftime('%s', effect_started_at) and " <>
      "strftime('%s', json_extract(evidence, '#{path}.observed_at')) <= " <>
      "strftime('%s', effect_finished_at), 0) and " <>
      "json_remove(json_extract(evidence, '#{path}'), '$.version', '$.observed_at', '$.root_identity') = '{}'"
  end

  defp absence_check(:postgres) do
    expression = "evidence->'anchored_absence'"
    nested = "(#{expression})"

    "jsonb_typeof(#{nested}) = 'object' and #{nested}->'version' = '1'::jsonb and " <>
      "jsonb_typeof(#{nested}->'observed_at') = 'string' and " <>
      identity_check(:postgres, "anchored_absence,root_identity") <>
      " and " <>
      utc_timestamp_check(:postgres, "anchored_absence.observed_at") <>
      " and evidence #>> '{anchored_absence,observed_at}' >= to_char(effect_started_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') and " <>
      "evidence #>> '{anchored_absence,observed_at}' <= to_char(effect_finished_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') and " <>
      "(#{nested} - array['version','observed_at','root_identity']::text[]) = '{}'::jsonb"
  end

  defp add_postgres_operation_checks do
    execute(
      "ALTER TABLE git_write_operations ADD CONSTRAINT git_write_operations_lease_pair_check CHECK (#{@git_pair_check})"
    )

    execute(
      "ALTER TABLE git_write_operations ADD CONSTRAINT git_write_operations_terminal_lease_check CHECK (#{@git_terminal_check})"
    )

    execute(
      "ALTER TABLE pull_merge_operations ADD CONSTRAINT pull_merge_operations_lease_pair_check CHECK (#{@git_pair_check})"
    )

    execute(
      "ALTER TABLE pull_merge_operations ADD CONSTRAINT pull_merge_operations_terminal_lease_check CHECK (#{@merge_terminal_check})"
    )
  end

  defp rebuild_turso_operation_tables do
    migration_repo = repo()

    migration_repo.checkout(
      fn ->
        query!(migration_repo, "PRAGMA foreign_keys = OFF")

        try do
          Enum.each(turso_git_write_statements(), &query!(migration_repo, &1))
          Enum.each(turso_pull_merge_statements(), &query!(migration_repo, &1))
        after
          query!(migration_repo, "PRAGMA foreign_keys = ON")
        end
      end,
      timeout: :infinity
    )
  end

  defp turso_git_write_statements do
    [
      """
      CREATE TABLE git_write_operations_with_cleanup_recovery (
        id INTEGER PRIMARY KEY,
        repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        actor_user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
        request_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        state TEXT NOT NULL,
        target_ref TEXT NOT NULL,
        expected_oid TEXT,
        proposed_oid TEXT NOT NULL,
        result_blob_oid TEXT,
        failure_reason TEXT,
        lease_owner TEXT,
        lease_expires_at TEXT,
        lock_version INTEGER NOT NULL DEFAULT 0,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        CONSTRAINT git_write_operations_lease_pair_check CHECK (#{@git_pair_check}),
        CONSTRAINT git_write_operations_terminal_lease_check CHECK (#{@git_terminal_check})
      )
      """,
      """
      INSERT INTO git_write_operations_with_cleanup_recovery
        (id, repository_id, actor_user_id, request_id, kind, state, target_ref,
         expected_oid, proposed_oid, result_blob_oid, failure_reason, lease_owner,
         lease_expires_at, lock_version, inserted_at, updated_at)
      SELECT id, repository_id, actor_user_id, request_id, kind, state, target_ref,
             expected_oid, proposed_oid, result_blob_oid, failure_reason, lease_owner,
             lease_expires_at, lock_version, inserted_at, updated_at
      FROM git_write_operations
      """,
      "DROP TABLE git_write_operations",
      "ALTER TABLE git_write_operations_with_cleanup_recovery RENAME TO git_write_operations",
      "CREATE INDEX git_write_operations_recovery_index ON git_write_operations (repository_id, state, id)",
      "CREATE INDEX git_write_operations_lease_index ON git_write_operations (lease_expires_at)",
      "CREATE UNIQUE INDEX git_write_operations_request_ref_index ON git_write_operations (request_id, kind, target_ref)"
    ]
  end

  defp turso_pull_merge_statements do
    [
      """
      CREATE TABLE pull_merge_operations_with_cleanup_recovery (
        id INTEGER PRIMARY KEY,
        pull_request_id INTEGER NOT NULL REFERENCES pull_requests(id) ON DELETE CASCADE,
        repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        actor_user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
        request_id TEXT NOT NULL,
        api_version TEXT,
        ip_address TEXT,
        user_agent TEXT,
        token_id TEXT,
        base_ref TEXT NOT NULL,
        head_ref TEXT NOT NULL,
        expected_base_oid TEXT NOT NULL,
        expected_head_oid TEXT NOT NULL,
        merge_oid TEXT,
        state TEXT NOT NULL CONSTRAINT pull_merge_operations_state_check
          CHECK (state IN ('prepared', 'merge_written', 'ref_advanced', 'completed', 'failed')),
        lease_owner TEXT,
        lease_expires_at TEXT,
        failure_reason TEXT,
        lock_version INTEGER NOT NULL DEFAULT 0,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        CONSTRAINT pull_merge_operations_lease_pair_check CHECK (#{@git_pair_check}),
        CONSTRAINT pull_merge_operations_terminal_lease_check CHECK (#{@merge_terminal_check})
      )
      """,
      """
      INSERT INTO pull_merge_operations_with_cleanup_recovery
        (id, pull_request_id, repository_id, actor_user_id, request_id, api_version,
         ip_address, user_agent, token_id, base_ref, head_ref, expected_base_oid,
         expected_head_oid, merge_oid, state, lease_owner, lease_expires_at,
         failure_reason, lock_version, inserted_at, updated_at)
      SELECT id, pull_request_id, repository_id, actor_user_id, request_id, api_version,
             ip_address, user_agent, token_id, base_ref, head_ref, expected_base_oid,
             expected_head_oid, merge_oid, state, lease_owner, lease_expires_at,
             failure_reason, lock_version, inserted_at, updated_at
      FROM pull_merge_operations
      """,
      "DROP TABLE pull_merge_operations",
      "ALTER TABLE pull_merge_operations_with_cleanup_recovery RENAME TO pull_merge_operations",
      "CREATE INDEX pull_merge_operations_repository_id_state_index ON pull_merge_operations (repository_id, state)",
      "CREATE INDEX pull_merge_operations_pull_request_id_state_index ON pull_merge_operations (pull_request_id, state)",
      "CREATE INDEX pull_merge_operations_lease_expires_at_index ON pull_merge_operations (lease_expires_at)"
    ]
  end

  defp column_options(options, name, expression) do
    if turso?(),
      do: Keyword.put(options, :check, name: to_string(name), expr: expression),
      else: options
  end

  defp postgres_check(table, name, expression) do
    unless turso?(), do: create(constraint(table, name, check: expression))
  end

  defp query!(migration_repo, sql),
    do: Ecto.Adapters.SQL.query!(migration_repo, sql, [], log: false)

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
