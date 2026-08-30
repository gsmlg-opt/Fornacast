defmodule FornacastAPI.ComposeBackupRestoreContractTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @root Path.expand("../../..", __DIR__)
  @compose Path.join(@root, "docker-compose.yml")
  @backup Path.join(@root, "scripts/compose_backup.sh")
  @restore Path.join(@root, "scripts/compose_restore.sh")

  test "recovery scripts anchor Compose, lock the daemon project, and use exact volume mounts" do
    backup = File.read!(@backup)
    restore = File.read!(@restore)

    assert executable_mode(@backup) == 0o755
    assert executable_mode(@restore) == 0o755
    assert {"", 0} = System.cmd("bash", ["-n", @backup, @restore], stderr_to_stdout: true)

    for source <- [backup, restore] do
      assert source =~ "#!/bin/sh\nset -eu\numask 077"
      assert source =~ ~S|script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)|
      assert source =~ ~S|project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)|
      assert source =~ ~S|compose_file=$project_root/docker-compose.yml|
      assert source =~ ~S|-f "$compose_file"|

      assert source =~
               ~S|docker compose --project-directory "$project_root" --file "$compose_file" "$@"|

      assert source =~
               ~S|docker compose --project-directory "$project_root" --file "$compose_file" --project-name "$expected_project" "$@"|

      assert occurrences(source, "docker compose ") == 2
      assert source =~ "compose_seed config --format json --no-interpolate"
      assert source =~ "1048576"
      assert source =~ "invalid Compose project name"
      assert source =~ ~S|lock_container=fornacast-recovery-lock-$expected_project|
      assert source =~ "invalid recovery lock container name"
      assert source =~ ~S|docker create --name "$lock_container"|
      assert source =~ ~S|docker rm "$lock_container"|
      assert source =~ "recovery lock already exists"
      assert source =~ ~S|app_project" != "$expected_project|
      assert source =~ ~S|.Destination "/data"|
      assert source =~ "data_mount_count"
      assert source =~ "volume:?*"
      assert source =~ "compose start --wait --wait-timeout 120 app nginx"
      refute source =~ "--volumes-from"
      refute source =~ ~S|echo "$POSTGRES_PASSWORD"|
      refute source =~ "set -x"
      refute source =~ ~S|rm -rf "$lock_container"|
      refute source =~ ~S|rm -rf "$staging_dir"|
    end

    assert backup =~
             ~S|--mount "type=volume,source=$data_volume,target=/data,readonly"|

    backup_main = after_marker(backup, "writers_stopped=true")

    assert_in_order(backup_main, [
      "compose stop nginx app",
      ~S|'exec pg_dump --username="$POSTGRES_USER" --format=custom --no-owner --no-privileges "$POSTGRES_DB"'|,
      ~S|--mount "type=volume,source=$data_volume,target=/data,readonly"|,
      "sha256sum fornacast.dump fornacast-data.tgz >SHA256SUMS",
      "sync",
      "compose start --wait --wait-timeout 120 app nginx"
    ])

    assert_in_order(backup, [
      ~S|mkdir -- "$backup_dir"|,
      ~S|backup_dir=$(CDPATH= cd -- "$backup_dir" && pwd)|,
      "writers_stopped=true"
    ])

    assert restore =~ ~S|-L "$backup_dir/$artifact"|

    assert restore =~
             ~S|staging_dir=$(mktemp -d "$tmp_root/fornacast-restore-$expected_project.XXXXXX")|

    assert restore =~ ~S|cp -P -- "$backup_dir/SHA256SUMS" "$staging_dir/SHA256SUMS"|
    assert restore =~ ~S|cp -P -- "$backup_dir/fornacast.dump" "$staging_dir/fornacast.dump"|

    assert restore =~
             ~S|cp -P -- "$backup_dir/fornacast-data.tgz" "$staging_dir/fornacast-data.tgz"|

    assert restore =~ ~S|chmod 600 "$staging_dir/SHA256SUMS"|
    assert restore =~ ~S|chmod 600 "$staging_dir/fornacast.dump"|
    assert restore =~ ~S|chmod 600 "$staging_dir/fornacast-data.tgz"|
    assert restore =~ ~S|(cd "$staging_dir" && sha256sum -c SHA256SUMS)|
    assert restore =~ ~S|<"$staging_dir/fornacast.dump"|
    assert restore =~ ~S|tar -tzf "$staging_dir/fornacast-data.tgz"|
    assert restore =~ ~S|--mount "type=volume,source=$data_volume,target=/data"|
    refute restore =~ ~S|<"$backup_dir/fornacast.dump"|
    refute restore =~ ~S|<"$backup_dir/fornacast-data.tgz"|

    restore_validation = after_marker(restore, "staging_dir=$(mktemp -d")

    assert_in_order(restore_validation, [
      ~S|cp -P -- "$backup_dir/SHA256SUMS"|,
      ~S|(cd "$staging_dir" && sha256sum -c SHA256SUMS)|,
      ~S|'exec pg_restore --list >/dev/null'|,
      ~S|tar -tzf "$staging_dir/fornacast-data.tgz" >/dev/null|,
      ~S|[ "$confirmation" != "--confirm-destroy" ]|,
      "resolve_app_identity",
      "compose stop nginx app",
      ~S|'exec dropdb --username="$POSTGRES_USER" --force --if-exists "$POSTGRES_DB"'|,
      ~S|'exec createdb --username="$POSTGRES_USER" --owner="$POSTGRES_USER" "$POSTGRES_DB"'|,
      ~S|'exec pg_restore --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --no-owner --no-privileges --exit-on-error'|,
      ~S|'test -d /data; find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'|,
      ~S|tar -C /data -xzf - <"$staging_dir/fornacast-data.tgz"|,
      "compose start --wait --wait-timeout 120 app nginx",
      ~S|"$script_dir/api_proxy_smoke.sh" "${FORNACAST_PUBLIC_URL:-http://127.0.0.1:4000}"|
    ])
  end

  test "backup anchors hostile caller context and creates private durable artifacts", %{
    tmp_dir: tmp_dir
  } do
    fake = install_fake_project(tmp_dir)
    backup_dir = Path.join(tmp_dir, "backup")

    assert {output, 0} = run(fake.backup, [backup_dir], fake)
    assert output == ""
    assert executable_mode(backup_dir) == 0o700

    for artifact <- ["fornacast.dump", "fornacast-data.tgz", "SHA256SUMS"] do
      assert executable_mode(Path.join(backup_dir, artifact)) == 0o600
    end

    assert File.read!(Path.join(backup_dir, "SHA256SUMS")) ==
             "#{String.duplicate("0", 64)}  fornacast.dump\n" <>
               "#{String.duplicate("0", 64)}  fornacast-data.tgz\n"

    assert actions(fake) == [
             "compose_config",
             "lock_create",
             "ps_app",
             "inspect_service",
             "inspect_project",
             "inspect_mount",
             "stop",
             "pg_dump",
             "archive_ro:fake-volume",
             "sha_write",
             "sync",
             "start_wait",
             "lock_remove"
           ]

    refute File.exists?(daemon_lock_path(fake))
  end

  test "backup failures after stopping writers preserve status and re-stop", %{tmp_dir: tmp_dir} do
    for {action, forbidden} <- [
          {"pg_dump", ["archive_ro", "sha_write", "sync", "start_wait"]},
          {"start_wait", []}
        ] do
      case_root = Path.join(tmp_dir, action)
      File.mkdir_p!(case_root)
      fake = install_fake_project(case_root)
      backup_dir = Path.join(case_root, "backup")

      assert {output, 91} =
               run(fake.backup, [backup_dir], fake, %{"FAKE_FAIL_ACTION" => action})

      assert output =~
               "backup failed; app and nginx remain stopped; inspect the partial backup before restarting"

      action_log = actions(fake)
      assert Enum.count(action_log, &(&1 == "stop")) == 2

      Enum.each(forbidden, fn value ->
        refute Enum.any?(action_log, &String.starts_with?(&1, value))
      end)

      refute File.exists?(daemon_lock_path(fake))
    end
  end

  test "a daemon-global stale recovery lock blocks both operations across TMPDIR values", %{
    tmp_dir: tmp_dir
  } do
    fake = install_fake_project(tmp_dir)
    backup_dir = Path.join(tmp_dir, "backup")
    recovery_set = write_recovery_set(tmp_dir)
    File.mkdir!(daemon_lock_path(fake))

    first_tmp = Path.join(tmp_dir, "client-a-tmp")
    second_tmp = Path.join(tmp_dir, "client-b-tmp")
    File.mkdir!(first_tmp)
    File.mkdir!(second_tmp)

    assert {backup_output, backup_status} =
             run(fake.backup, [backup_dir], fake, %{"TMPDIR" => first_tmp})

    assert backup_status != 0
    assert backup_output =~ "recovery lock already exists"
    assert backup_output =~ "inspect the active or stale lock and remove it only when safe"
    assert actions(fake) == ["compose_config", "lock_create", "lock_conflict"]

    File.write!(fake.action_log, "")

    assert {restore_output, restore_status} =
             run(fake.restore, [recovery_set, "--confirm-destroy"], fake, %{
               "TMPDIR" => second_tmp
             })

    assert restore_status != 0
    assert restore_output =~ "recovery lock already exists"
    assert actions(fake) == ["compose_config", "lock_create", "lock_conflict"]
    assert File.dir?(daemon_lock_path(fake))
  end

  test "overlapping clients with different TMPDIR values share one daemon lock", %{
    tmp_dir: tmp_dir
  } do
    fake = install_fake_project(tmp_dir)
    first_tmp = Path.join(tmp_dir, "client-a-tmp")
    second_tmp = Path.join(tmp_dir, "client-b-tmp")
    second_log = Path.join(tmp_dir, "second-actions.log")
    hold_ready = Path.join(tmp_dir, "hold-ready")
    hold_release = Path.join(tmp_dir, "hold-release")
    File.mkdir!(first_tmp)
    File.mkdir!(second_tmp)

    first =
      Task.async(fn ->
        run(fake.backup, [Path.join(tmp_dir, "overlap-backup")], fake, %{
          "FAKE_HOLD_ACTION" => "pg_dump",
          "FAKE_HOLD_READY" => hold_ready,
          "FAKE_HOLD_RELEASE" => hold_release,
          "TMPDIR" => first_tmp
        })
      end)

    ready? = wait_for_file(hold_ready)

    second = %{fake | action_log: second_log}
    recovery_set = write_recovery_set(tmp_dir)

    second_result =
      if ready? do
        run(second.restore, [recovery_set, "--confirm-destroy"], second, %{
          "TMPDIR" => second_tmp
        })
      else
        {"first operation never reached the hold point", 99}
      end

    File.touch!(hold_release)
    first_result = Task.await(first, 5_000)

    assert ready?
    assert {"", 0} = first_result
    assert {second_output, second_status} = second_result
    assert second_status != 0
    assert second_output =~ "recovery lock already exists"
    assert actions(second) == ["compose_config", "lock_create", "lock_conflict"]
    assert_no_mutations(actions(second))
    refute File.exists?(daemon_lock_path(fake))
  end

  test "backup canonicalizes a leading-hyphen relative destination before stopping writers", %{
    tmp_dir: tmp_dir
  } do
    fake = install_fake_project(tmp_dir)

    assert {output, 0} = run(fake.backup, ["-backup"], fake)
    assert output == ""

    backup_dir = Path.join(fake.wrong_cwd, "-backup")
    assert executable_mode(backup_dir) == 0o700

    for artifact <- ["fornacast.dump", "fornacast-data.tgz", "SHA256SUMS"] do
      assert executable_mode(Path.join(backup_dir, artifact)) == 0o600
    end

    refute File.exists?(daemon_lock_path(fake))
  end

  test "failed emergency stops never falsely claim writers remain stopped", %{tmp_dir: tmp_dir} do
    for script_kind <- [:backup, :restore] do
      case_root = Path.join(tmp_dir, Atom.to_string(script_kind))
      File.mkdir_p!(case_root)
      fake = install_fake_project(case_root)

      {script, arguments, failure} =
        case script_kind do
          :backup ->
            {fake.backup, [Path.join(case_root, "backup")], "pg_dump"}

          :restore ->
            {fake.restore, [write_recovery_set(case_root), "--confirm-destroy"], "createdb"}
        end

      assert {output, 91} =
               run(script, arguments, fake, %{
                 "FAKE_FAIL_ACTION" => failure,
                 "FAKE_FAIL_EMERGENCY_STOP" => "true"
               })

      assert output =~ "could not confirm app and nginx are stopped"
      assert output =~ "verify both writers manually and do not restart"
      refute output =~ "app and nginx remain stopped"
      assert Enum.count(actions(fake), &(&1 == "stop")) == 2
      refute File.exists?(daemon_lock_path(fake))
    end
  end

  test "lock cleanup failure leaves the daemon lock and preserves an earlier failure", %{
    tmp_dir: tmp_dir
  } do
    fake = install_fake_project(tmp_dir)

    assert {output, 91} =
             run(fake.backup, [Path.join(tmp_dir, "backup")], fake, %{
               "FAKE_FAIL_ACTION" => "pg_dump",
               "FAKE_FAIL_LOCK_REMOVE" => "true"
             })

    assert output =~ "could not release recovery lock container"
    assert File.dir?(daemon_lock_path(fake))
  end

  test "invalid project names and mismatched project labels fail before mutation", %{
    tmp_dir: tmp_dir
  } do
    invalid_root = Path.join(tmp_dir, "invalid-name")
    File.mkdir_p!(invalid_root)
    invalid = install_fake_project(invalid_root)

    assert {invalid_output, invalid_status} =
             run(invalid.backup, [Path.join(invalid_root, "backup")], invalid, %{
               "FAKE_EXPECTED_PROJECT" => "Bad Project"
             })

    assert invalid_status != 0
    assert invalid_output =~ "invalid Compose project name"
    assert_no_mutations(actions(invalid))

    for script_kind <- [:backup, :restore] do
      case_root = Path.join(tmp_dir, Atom.to_string(script_kind))
      File.mkdir_p!(case_root)
      fake = install_fake_project(case_root)

      {script, arguments} =
        case script_kind do
          :backup -> {fake.backup, [Path.join(case_root, "backup")]}
          :restore -> {fake.restore, [write_recovery_set(case_root), "--confirm-destroy"]}
        end

      assert {output, status} =
               run(script, arguments, fake, %{"FAKE_APP_PROJECT" => "other-project"})

      assert status != 0
      assert output =~ "without exact Compose labels"
      assert_no_mutations(actions(fake))
      refute File.exists?(daemon_lock_path(fake))
    end
  end

  test "both operations reject ambiguous containers and unsafe data volume identities", %{
    tmp_dir: tmp_dir
  } do
    cases = [
      {%{"FAKE_APP_IDS" => "first\nsecond"}, "exactly one Compose app container"},
      {%{"FAKE_APP_SERVICE" => "worker"}, "without exact Compose labels"},
      {%{"FAKE_DATA_MOUNTS" => "bind:"}, "without one named volume at /data"},
      {%{"FAKE_DATA_MOUNTS" => "volume:first\nvolume:second"},
       "without one named volume at /data"},
      {%{"FAKE_DATA_MOUNTS" => "volume:unsafe/name"}, "invalid named volume"}
    ]

    Enum.with_index(cases, fn {overrides, expected}, index ->
      for script_kind <- [:backup, :restore] do
        case_root = Path.join([tmp_dir, Integer.to_string(index), Atom.to_string(script_kind)])
        File.mkdir_p!(case_root)
        fake = install_fake_project(case_root)

        {script, arguments} =
          case script_kind do
            :backup -> {fake.backup, [Path.join(case_root, "backup")]}
            :restore -> {fake.restore, [write_recovery_set(case_root), "--confirm-destroy"]}
          end

        assert {output, status} = run(script, arguments, fake, overrides)
        assert status != 0
        assert output =~ expected
        assert_no_mutations(actions(fake))
      end
    end)
  end

  test "restore rejects source symlinks before validation or mutation", %{tmp_dir: tmp_dir} do
    for artifact <- ["SHA256SUMS", "fornacast.dump", "fornacast-data.tgz"] do
      case_root = Path.join(tmp_dir, artifact)
      File.mkdir_p!(case_root)
      fake = install_fake_project(case_root)
      recovery_set = write_recovery_set(case_root)
      source = Path.join(recovery_set, artifact)
      target = Path.join(recovery_set, artifact <> ".target")
      File.rename!(source, target)
      File.ln_s!(target, source)

      assert {output, status} = run(fake.restore, [recovery_set, "--confirm-destroy"], fake)
      assert status != 0
      assert output =~ "backup artifact must be a regular non-symlink file"
      assert actions(fake) == ["compose_config", "lock_create", "lock_remove"]
      refute File.exists?(daemon_lock_path(fake))
    end
  end

  test "restore integrity failure and declined confirmation perform no mutation", %{
    tmp_dir: tmp_dir
  } do
    failure_root = Path.join(tmp_dir, "integrity")
    File.mkdir_p!(failure_root)
    integrity = install_fake_project(failure_root)
    recovery_set = write_recovery_set(failure_root)

    assert {_output, 91} =
             run(integrity.restore, [recovery_set, "--confirm-destroy"], integrity, %{
               "FAKE_FAIL_ACTION" => "sha_check"
             })

    assert_no_mutations(actions(integrity))
    refute File.exists?(daemon_lock_path(integrity))

    declined_root = Path.join(tmp_dir, "declined")
    File.mkdir_p!(declined_root)
    declined = install_fake_project(declined_root)
    recovery_set = write_recovery_set(declined_root)

    assert {output, 64} = run(declined.restore, [recovery_set, "not-confirmed"], declined)
    assert output =~ "restore is destructive; pass --confirm-destroy"

    assert Enum.map(actions(declined), &normalize_action/1) == [
             "compose_config",
             "lock_create",
             "sha_check",
             "pg_restore_list",
             "tar_list",
             "lock_remove"
           ]

    assert_no_mutations(actions(declined))
    refute File.exists?(daemon_lock_path(declined))
  end

  test "restore stages one immutable recovery set and succeeds without network access", %{
    tmp_dir: tmp_dir
  } do
    fake = install_fake_project(tmp_dir)
    recovery_set = write_recovery_set(tmp_dir)

    assert {output, 0} =
             run(fake.restore, [recovery_set, "--confirm-destroy"], fake, %{
               "FAKE_SWAP_SOURCE_DIR" => recovery_set
             })

    assert output == ""
    assert File.read!(Path.join(recovery_set, "fornacast.dump")) == "swapped-dump"
    assert File.read!(Path.join(recovery_set, "fornacast-data.tgz")) == "swapped-archive"
    assert File.read!(fake.list_capture) == "dump"
    assert File.read!(fake.restore_capture) == "dump"
    assert File.read!(fake.extract_capture) == "archive"

    action_log = actions(fake)

    assert Enum.map(action_log, &normalize_action/1) == [
             "compose_config",
             "lock_create",
             "sha_check",
             "pg_restore_list",
             "tar_list",
             "ps_app",
             "inspect_service",
             "inspect_project",
             "inspect_mount",
             "stop",
             "dropdb",
             "createdb",
             "pg_restore",
             "clear_rw:fake-volume",
             "extract_rw:fake-volume",
             "start_wait",
             "smoke",
             "lock_remove"
           ]

    staging_dir = staging_dir_from_actions(action_log)
    refute String.starts_with?(staging_dir, recovery_set)
    refute File.exists?(staging_dir)
    refute File.exists?(daemon_lock_path(fake))
  end

  test "late restore failures re-stop writers and preserve original status", %{tmp_dir: tmp_dir} do
    for action <- ["createdb", "extract_rw", "start_wait", "smoke"] do
      case_root = Path.join(tmp_dir, action)
      File.mkdir_p!(case_root)
      fake = install_fake_project(case_root)
      recovery_set = write_recovery_set(case_root)

      assert {output, 91} =
               run(fake.restore, [recovery_set, "--confirm-destroy"], fake, %{
                 "FAKE_FAIL_ACTION" => action
               })

      assert output =~
               "restore failed; app and nginx remain stopped; repair the recovery set before restarting"

      action_log = actions(fake)
      assert Enum.count(action_log, &(&1 == "stop")) == 2

      case action do
        "createdb" ->
          refute "pg_restore" in action_log

        "extract_rw" ->
          refute "start_wait" in action_log

        "start_wait" ->
          refute "smoke" in action_log

        "smoke" ->
          assert "start_wait" in action_log
      end

      refute File.exists?(daemon_lock_path(fake))
    end
  end

  defp install_fake_project(tmp_dir) do
    project_root = Path.join(tmp_dir, "anchored-project")
    scripts_dir = Path.join(project_root, "scripts")
    bin_dir = Path.join(tmp_dir, "fake-bin")
    tmp_root = Path.join(tmp_dir, "tmp")
    wrong_cwd = Path.join(tmp_dir, "wrong-cwd")
    compose_file = Path.join(project_root, "docker-compose.yml")
    backup = Path.join(scripts_dir, "compose_backup.sh")
    restore = Path.join(scripts_dir, "compose_restore.sh")
    action_log = Path.join(tmp_dir, "actions.log")
    daemon_lock_root = Path.join(tmp_dir, "fake-daemon-locks")

    for path <- [scripts_dir, bin_dir, tmp_root, wrong_cwd, daemon_lock_root] do
      File.mkdir_p!(path)
    end

    File.cp!(@compose, compose_file)
    File.cp!(@backup, backup)
    File.cp!(@restore, restore)
    File.chmod!(backup, 0o755)
    File.chmod!(restore, 0o755)
    File.write!(Path.join(tmp_dir, "hostile-compose.yml"), "services: {}\n")

    write_executable!(
      Path.join(scripts_dir, "api_proxy_smoke.sh"),
      ~S"""
      #!/bin/sh
      set -eu
      if [ "$#" -ne 1 ] || [ "$1" != "${FORNACAST_PUBLIC_URL:-http://127.0.0.1:4000}" ]; then
        exit 97
      fi
      printf 'smoke\n' >>"$FAKE_ACTION_LOG"
      if [ "${FAKE_FAIL_ACTION-}" = smoke ]; then exit 91; fi
      """
    )

    install_fake_docker!(bin_dir)
    install_fake_sha256sum!(bin_dir)
    install_fake_tar!(bin_dir)
    install_fake_sync!(bin_dir)

    %{
      action_log: action_log,
      backup: backup,
      bin_dir: bin_dir,
      compose_file: compose_file,
      daemon_lock_root: daemon_lock_root,
      extract_capture: Path.join(tmp_dir, "extract.capture"),
      hostile_compose: Path.join(tmp_dir, "hostile-compose.yml"),
      list_capture: Path.join(tmp_dir, "list.capture"),
      project_root: project_root,
      restore: restore,
      restore_capture: Path.join(tmp_dir, "restore.capture"),
      stop_count: Path.join(tmp_dir, "stop.count"),
      tmp_root: tmp_root,
      wrong_cwd: wrong_cwd
    }
  end

  defp install_fake_docker!(bin_dir) do
    write_executable!(
      Path.join(bin_dir, "docker"),
      ~S"""
      #!/bin/sh
      set -eu

      record() { printf '%s\n' "$1" >>"$FAKE_ACTION_LOG"; }
      fail_if_requested() {
        if [ "${FAKE_FAIL_ACTION-}" = "$1" ]; then exit 91; fi
      }
      unknown() {
        printf 'unexpected fake docker command:' >&2
        printf ' %s' "$@" >&2
        printf '\n' >&2
        exit 97
      }

      lock_name=fornacast-recovery-lock-${FAKE_EXPECTED_PROJECT-fake-project}

      if [ "$*" = "create --name $lock_name --network none alpine:3.22 sh -c exit 0" ]; then
        record lock_create
        if mkdir "$FAKE_DAEMON_LOCK_ROOT/$lock_name" 2>/dev/null; then
          printf 'fake-lock-container-id\n'
          exit 0
        fi
        record lock_conflict
        exit 75
      fi

      if [ "$*" = "rm $lock_name" ]; then
        record lock_remove
        if [ "${FAKE_FAIL_LOCK_REMOVE-false}" = true ]; then exit 92; fi
        if [ "${FAKE_FAIL_ACTION-}" = lock_remove ]; then exit 91; fi
        rmdir "$FAKE_DAEMON_LOCK_ROOT/$lock_name" || exit 97
        printf '%s\n' "$lock_name"
        exit 0
      fi

      if [ "${1-}" = compose ]; then
        [ "${2-}" = --project-directory ] || unknown "$@"
        [ "${3-}" = "$FAKE_PROJECT_ROOT" ] || unknown "$@"
        [ "${4-}" = --file ] || unknown "$@"
        [ "${5-}" = "$FAKE_COMPOSE_FILE" ] || unknown "$@"
        shift 5

        if [ "$*" = "config --format json --no-interpolate" ]; then
          record compose_config
          printf '{\n  "name": "%s",\n  "services": {}\n}\n' "${FAKE_EXPECTED_PROJECT-fake-project}"
          exit 0
        fi

        [ "${1-}" = --project-name ] || unknown "$@"
        [ "${2-}" = "${FAKE_EXPECTED_PROJECT-fake-project}" ] || unknown "$@"
        shift 2

        case "$*" in
          "ps -aq app")
            record ps_app
            printf '%s\n' "${FAKE_APP_IDS-app-container}"
            exit 0
            ;;
          "stop nginx app")
            record stop
            stop_count=0
            if [ -f "$FAKE_STOP_COUNT_FILE" ]; then
              stop_count=$(cat "$FAKE_STOP_COUNT_FILE")
            fi
            stop_count=$((stop_count + 1))
            printf '%s\n' "$stop_count" >"$FAKE_STOP_COUNT_FILE"
            if [ "${FAKE_FAIL_EMERGENCY_STOP-false}" = true ] && [ "$stop_count" -gt 1 ]; then
              exit 92
            fi
            fail_if_requested stop
            exit 0
            ;;
          "start --wait --wait-timeout 120 app nginx")
            record start_wait
            fail_if_requested start_wait
            exit 0
            ;;
        esac

        pg_dump_command='exec -T db sh -eu -c exec pg_dump --username="$POSTGRES_USER" --format=custom --no-owner --no-privileges "$POSTGRES_DB"'
        pg_restore_list_command='exec -T db sh -eu -c exec pg_restore --list >/dev/null'
        dropdb_command='exec -T db sh -eu -c exec dropdb --username="$POSTGRES_USER" --force --if-exists "$POSTGRES_DB"'
        createdb_command='exec -T db sh -eu -c exec createdb --username="$POSTGRES_USER" --owner="$POSTGRES_USER" "$POSTGRES_DB"'
        pg_restore_command='exec -T db sh -eu -c exec pg_restore --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --no-owner --no-privileges --exit-on-error'

        if [ "$*" = "$pg_dump_command" ]; then
          record pg_dump
          fail_if_requested pg_dump
          if [ "${FAKE_HOLD_ACTION-}" = pg_dump ]; then
            : >"$FAKE_HOLD_READY"
            hold_attempt=0
            while [ ! -f "$FAKE_HOLD_RELEASE" ]; do
              hold_attempt=$((hold_attempt + 1))
              if [ "$hold_attempt" -gt 500 ]; then exit 96; fi
              sleep 0.01
            done
          fi
          printf 'fake-postgresql-dump\n'
          exit 0
        fi

        if [ "$*" = "$pg_restore_list_command" ]; then
          record pg_restore_list
          cat >"$FAKE_LIST_CAPTURE"
          if [ -n "${FAKE_SWAP_SOURCE_DIR-}" ]; then
            printf 'swapped-dump' >"$FAKE_SWAP_SOURCE_DIR/fornacast.dump"
            printf 'swapped-archive' >"$FAKE_SWAP_SOURCE_DIR/fornacast-data.tgz"
          fi
          fail_if_requested pg_restore_list
          exit 0
        fi

        if [ "$*" = "$dropdb_command" ]; then
          record dropdb
          fail_if_requested dropdb
          exit 0
        fi

        if [ "$*" = "$createdb_command" ]; then
          record createdb
          fail_if_requested createdb
          exit 0
        fi

        if [ "$*" = "$pg_restore_command" ]; then
          record pg_restore
          cat >"$FAKE_RESTORE_CAPTURE"
          fail_if_requested pg_restore
          exit 0
        fi

        unknown compose --project-directory "$FAKE_PROJECT_ROOT" --file "$FAKE_COMPOSE_FILE" --project-name "${FAKE_EXPECTED_PROJECT-fake-project}" "$@"
      fi

      if [ "${1-}" = inspect ] && [ "${2-}" = --format ] && [ "$#" -eq 4 ]; then
        case "$3" in
          *com.docker.compose.service*)
            record inspect_service
            printf '%s\n' "${FAKE_APP_SERVICE-app}"
            ;;
          *com.docker.compose.project*)
            record inspect_project
            printf '%s\n' "${FAKE_APP_PROJECT-fake-project}"
            ;;
          *.Destination*)
            record inspect_mount
            printf '%s\n' "${FAKE_DATA_MOUNTS-volume:${FAKE_VOLUME_NAME-fake-volume}}"
            ;;
          *) unknown "$@" ;;
        esac
        exit 0
      fi

      if [ "${1-}" = run ] && [ "${2-}" = --rm ] && [ "${3-}" = --mount ]; then
        volume_name=${FAKE_VOLUME_NAME-fake-volume}
        archive_command="run --rm --mount type=volume,source=$volume_name,target=/data,readonly alpine:3.22 tar -C /data -czf - ."
        clear_command="run --rm --mount type=volume,source=$volume_name,target=/data alpine:3.22 sh -eu -c test -d /data; find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"

        if [ "$*" = "$archive_command" ]; then
          record "archive_ro:$volume_name"
          fail_if_requested archive_ro
          printf 'fake-data-archive\n'
          exit 0
        fi

        if [ "$*" = "$clear_command" ]; then
          record "clear_rw:$volume_name"
          fail_if_requested clear_rw
          exit 0
        fi

        unknown "$@"
      fi

      if [ "${1-}" = run ] && [ "${2-}" = --rm ] && [ "${3-}" = -i ] && [ "${4-}" = --mount ]; then
        volume_name=${FAKE_VOLUME_NAME-fake-volume}
        extract_command="run --rm -i --mount type=volume,source=$volume_name,target=/data alpine:3.22 tar -C /data -xzf -"

        if [ "$*" = "$extract_command" ]; then
          record "extract_rw:$volume_name"
          cat >"$FAKE_EXTRACT_CAPTURE"
          fail_if_requested extract_rw
          exit 0
        fi

        unknown "$@"
      fi

      unknown "$@"
      """
    )
  end

  defp install_fake_sha256sum!(bin_dir) do
    write_executable!(
      Path.join(bin_dir, "sha256sum"),
      ~S"""
      #!/bin/sh
      set -eu

      if [ "$#" -eq 2 ] && [ "$1" = fornacast.dump ] && [ "$2" = fornacast-data.tgz ]; then
        printf 'sha_write\n' >>"$FAKE_ACTION_LOG"
        hash=0000000000000000000000000000000000000000000000000000000000000000
        printf '%s  fornacast.dump\n%s  fornacast-data.tgz\n' "$hash" "$hash"
        exit 0
      fi

      if [ "$#" -eq 2 ] && [ "$1" = -c ] && [ "$2" = SHA256SUMS ]; then
        printf 'sha_check:%s\n' "$PWD" >>"$FAKE_ACTION_LOG"
        if [ "${FAKE_FAIL_ACTION-}" = sha_check ]; then exit 91; fi
        exit 0
      fi

      echo "unexpected fake sha256sum command" >&2
      exit 97
      """
    )
  end

  defp install_fake_tar!(bin_dir) do
    write_executable!(
      Path.join(bin_dir, "tar"),
      ~S"""
      #!/bin/sh
      set -eu
      if [ "$#" -eq 2 ] && [ "$1" = -tzf ]; then
        printf 'tar_list:%s\n' "$2" >>"$FAKE_ACTION_LOG"
        if [ "${FAKE_FAIL_ACTION-}" = tar_list ]; then exit 91; fi
        exit 0
      fi
      echo "unexpected fake tar command" >&2
      exit 97
      """
    )
  end

  defp install_fake_sync!(bin_dir) do
    write_executable!(
      Path.join(bin_dir, "sync"),
      ~S"""
      #!/bin/sh
      set -eu
      [ "$#" -eq 0 ] || exit 97
      printf 'sync\n' >>"$FAKE_ACTION_LOG"
      if [ "${FAKE_FAIL_ACTION-}" = sync ]; then exit 91; fi
      """
    )
  end

  defp write_recovery_set(tmp_dir) do
    backup_dir = Path.join(tmp_dir, "recovery-set")
    File.mkdir_p!(backup_dir)
    File.write!(Path.join(backup_dir, "fornacast.dump"), "dump")
    File.write!(Path.join(backup_dir, "fornacast-data.tgz"), "archive")
    hash = String.duplicate("0", 64)

    File.write!(
      Path.join(backup_dir, "SHA256SUMS"),
      "#{hash}  fornacast.dump\n#{hash}  fornacast-data.tgz\n"
    )

    backup_dir
  end

  defp run(script, arguments, fake, overrides \\ %{}) do
    env =
      %{
        "COMPOSE_FILE" => fake.hostile_compose,
        "FAKE_ACTION_LOG" => fake.action_log,
        "FAKE_APP_PROJECT" => "fake-project",
        "FAKE_COMPOSE_FILE" => fake.compose_file,
        "FAKE_DAEMON_LOCK_ROOT" => fake.daemon_lock_root,
        "FAKE_EXTRACT_CAPTURE" => fake.extract_capture,
        "FAKE_LIST_CAPTURE" => fake.list_capture,
        "FAKE_PROJECT_ROOT" => fake.project_root,
        "FAKE_RESTORE_CAPTURE" => fake.restore_capture,
        "FAKE_STOP_COUNT_FILE" => fake.stop_count,
        "FAKE_VOLUME_NAME" => "fake-volume",
        "PATH" => fake.bin_dir <> ":" <> System.get_env("PATH", ""),
        "POSTGRES_PASSWORD" => "never-print-this-sentinel",
        "TMPDIR" => fake.tmp_root
      }
      |> Map.merge(overrides)
      |> Map.to_list()

    System.cmd(script, arguments,
      cd: fake.wrong_cwd,
      env: env,
      stderr_to_stdout: true
    )
  end

  defp actions(fake), do: fake.action_log |> read_log() |> String.split("\n", trim: true)

  defp normalize_action(action) do
    cond do
      String.starts_with?(action, "sha_check:") -> "sha_check"
      String.starts_with?(action, "tar_list:") -> "tar_list"
      true -> action
    end
  end

  defp staging_dir_from_actions(action_log) do
    action_log
    |> Enum.find(&String.starts_with?(&1, "sha_check:"))
    |> String.replace_prefix("sha_check:", "")
  end

  defp assert_no_mutations(action_log) do
    for mutation <- [
          "stop",
          "dropdb",
          "createdb",
          "pg_restore",
          "clear_rw",
          "extract_rw",
          "start_wait",
          "smoke"
        ] do
      refute Enum.any?(action_log, fn action ->
               action == mutation || String.starts_with?(action, mutation <> ":")
             end)
    end
  end

  defp daemon_lock_path(fake) do
    Path.join(fake.daemon_lock_root, "fornacast-recovery-lock-fake-project")
  end

  defp wait_for_file(path, attempts \\ 200)
  defp wait_for_file(_path, 0), do: false

  defp wait_for_file(path, attempts) do
    if File.exists?(path) do
      true
    else
      Process.sleep(10)
      wait_for_file(path, attempts - 1)
    end
  end

  defp write_executable!(path, source) do
    File.write!(path, source)
    File.chmod!(path, 0o755)
  end

  defp assert_in_order(source, values) do
    values
    |> Enum.map(&position!(source, &1))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [first, second] -> assert first < second end)
  end

  defp position!(source, value) do
    case :binary.match(source, value) do
      {position, _length} -> position
      :nomatch -> flunk("expected to find #{inspect(value)}")
    end
  end

  defp after_marker(source, marker) do
    case String.split(source, marker, parts: 2) do
      [_before, after_marker] -> after_marker
      _ -> flunk("expected to find #{inspect(marker)}")
    end
  end

  defp occurrences(source, value), do: length(:binary.matches(source, value))

  defp executable_mode(path) do
    path
    |> File.stat!()
    |> Map.fetch!(:mode)
    |> Bitwise.band(0o777)
  end

  defp read_log(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, :enoent} -> ""
    end
  end
end
