#!/usr/bin/env bash
set -u

if [[ -n "${MOCK_CI_GH_LOG:-}" ]]; then
  {
    printf 'gh'
    printf ' %q' "$@"
    printf '\n'
  } >> "$MOCK_CI_GH_LOG"
fi

subcommand="${1:-}"
shift || true

case "$subcommand" in
  repo)
    [[ "${1:-}" == "view" ]] || exit 97
    shift
    if [[ " $* " == *" --json id "* \
      && " $* " != *"nameWithOwner"* ]]; then
      if [[ "${MOCK_CI_REPO_ID_CHANGED:-0}" == "1" ]]; then
        printf '%s\n' "REPO-CHANGED"
      else
        printf '%s\n' "REPO-1"
      fi
    else
      printf '%s\n' \
        $'REPO-1\tacme/project\thttps://github.com/acme/project'
    fi
    ;;
  auth)
    [[ "${1:-}" == "status" ]] || exit 97
    exit 0
    ;;
  run)
    [[ "${1:-}" == "view" ]] || exit 97
    if [[ "${MOCK_CI_RUN_VIEW_ERROR:-0}" == "1" ]]; then
      printf '%s\n' \
        'Authorization: Bearer raw-run-view-error' >&2
      exit 1
    fi
    printf '%s\n' "Run details for ${2:-unknown}"
    ;;
  api)
    method="GET"
    endpoint=""
    while (( $# )); do
      case "$1" in
        --method)
          method="${2:-}"
          shift 2
          ;;
        --hostname)
          shift 2
          ;;
        -f)
          shift 2
          ;;
        -*)
          printf 'ci gh mock: unsupported API option: %s\n' "$1" >&2
          exit 97
          ;;
        *)
          if [[ -z "$endpoint" ]]; then
            endpoint="$1"
            shift
          else
            printf 'ci gh mock: unexpected API operand: %s\n' "$1" >&2
            exit 97
          fi
          ;;
      esac
    done

    if [[ "$method" == "GET" ]]; then
      case "$endpoint" in
        'repos/acme/project/actions/runs/1001'|'repos/acme/project/actions/runs/9001')
          [[ "${MOCK_CI_EXACT_ERROR:-0}" == "0" ]] || exit "$MOCK_CI_EXACT_ERROR"
          printf \
            '{"id":%s,"workflow_id":101,"status":"completed","conclusion":"success","name":"Build","head_branch":"main","created_at":"2026-07-20T10:00:00Z","event":"push","display_title":"old build","repository":{"node_id":"%s","full_name":"%s"}}\n' \
            "${MOCK_CI_EXACT_ID:-${endpoint##*/}}" \
            "${MOCK_CI_EXACT_REPO_ID:-REPO-1}" \
            "${MOCK_CI_EXACT_REPO_NAME:-acme/project}"
          ;;
        'repos/acme/project/actions/runs?per_page='*)
          if [[ -n "${MOCK_CI_RUNS_RESPONSE_FILE:-}" ]]; then
            cat "$MOCK_CI_RUNS_RESPONSE_FILE"
            exit 0
          fi
          if [[ "${MOCK_CI_INVALID_RESPONSE:-0}" == "1" ]]; then
            printf '%s\n' '{"workflow_runs":[{"id":"not-an-integer"}]}'
            exit 0
          fi
          if [[ -n "${MOCK_CI_RUNS_COUNT_FILE:-}" ]]; then
            count=0
            [[ -f "$MOCK_CI_RUNS_COUNT_FILE" ]] \
              && read -r count < "$MOCK_CI_RUNS_COUNT_FILE"
            count=$((count + 1))
            printf '%s\n' "$count" > "$MOCK_CI_RUNS_COUNT_FILE"
          else
            count=1
          fi
          if [[ "${MOCK_CI_DUPLICATE_RUN_ID:-0}" == "1" ]]; then
            cat <<'JSON'
{"workflow_runs":[{"id":1001,"workflow_id":101,"status":"completed","conclusion":"success","name":"Build","head_branch":"main","created_at":"2026-07-26T10:00:00Z","event":"push","display_title":"first"},{"id":1001,"workflow_id":101,"status":"completed","conclusion":"failure","name":"Build","head_branch":"main","created_at":"2026-07-25T10:00:00Z","event":"push","display_title":"duplicate"}]}
JSON
          elif [[ "${MOCK_CI_SECRET_CHANGED:-0}" == "1" ]]; then
            if [[ "$count" -ge 2 ]]; then
              secret_title="Authorization Bearer replacement-value"
            else
              secret_title="Authorization Bearer example-value"
            fi
            printf \
              '{"workflow_runs":[{"id":1002,"workflow_id":101,"status":"completed","conclusion":"success","name":"Build","head_branch":"main","created_at":"2026-07-26T10:00:00Z","event":"push","display_title":"latest"},{"id":1001,"workflow_id":101,"status":"completed","conclusion":"failure","name":"Build","head_branch":"feature","created_at":"2026-07-25T10:00:00Z","event":"pull_request","display_title":"%s"}]}\n' \
              "$secret_title"
          elif [[ "${MOCK_CI_RUNS_CHANGED:-0}" == "1" && "$count" -ge 2 ]]; then
            cat <<'JSON'
{"workflow_runs":[{"id":1001,"workflow_id":101,"status":"completed","conclusion":"success","name":"Build","head_branch":"main","created_at":"2026-07-27T10:00:00Z","event":"push","display_title":"changed"},{"id":1002,"workflow_id":101,"status":"completed","conclusion":"success","name":"Build","head_branch":"main","created_at":"2026-07-26T10:00:00Z","event":"push","display_title":"latest build"},{"id":2001,"workflow_id":102,"status":"in_progress","conclusion":null,"name":"Docs","head_branch":"main","created_at":"2026-07-26T11:00:00Z","event":"workflow_dispatch","display_title":"docs"}]}
JSON
          elif [[ "${MOCK_CI_SECRET_RESPONSE:-0}" == "1" ]]; then
            cat <<'JSON'
{"workflow_runs":[{"id":1002,"workflow_id":101,"status":"completed","conclusion":"success","name":"Build","head_branch":"main","created_at":"2026-07-26T10:00:00Z","event":"push","display_title":"Authorization Bearer example-value"}]}
JSON
          else
            cat <<'JSON'
{"workflow_runs":[{"id":1002,"workflow_id":101,"status":"completed","conclusion":"success","name":"Build","head_branch":"main","created_at":"2026-07-26T10:00:00Z","event":"push","display_title":"latest build"},{"id":1001,"workflow_id":101,"status":"completed","conclusion":"failure","name":"Build","head_branch":"feature","created_at":"2026-07-25T10:00:00Z","event":"pull_request","display_title":"older build"},{"id":2001,"workflow_id":102,"status":"in_progress","conclusion":null,"name":"Docs","head_branch":"main","created_at":"2026-07-26T11:00:00Z","event":"workflow_dispatch","display_title":"docs"}]}
JSON
          fi
          ;;
        'repos/acme/project/actions/workflows?per_page=100')
          cat <<'JSON'
{"workflows":[{"id":501,"name":"CI","path":".github/workflows/ci.yml","state":"active"},{"id":502,"name":"Legacy","path":".github/workflows/legacy.yaml","state":"disabled_manually"}]}
JSON
          ;;
        'repos/acme/project/git/ref/heads/main')
          printf \
            '{"ref":"refs/heads/main","object":{"type":"commit","sha":"%s"}}\n' \
            "${MOCK_CI_REF_OID:?}"
          ;;
        'repos/acme/project/deployments?per_page=100')
          if [[ "${MOCK_CI_EMPTY_DEPLOYMENTS:-0}" == "1" ]]; then
            printf '%s\n' '[]'
          else
            cat <<'JSON'
[{"id":3002,"environment":"production","creator":{"login":"acme-bot"},"created_at":"2026-07-26T10:00:00Z"},{"id":3001,"environment":"production","creator":{"login":"acme-bot"},"created_at":"2026-07-25T10:00:00Z"}]
JSON
          fi
          ;;
        'repos/acme/project/releases?per_page=100')
          cat <<'JSON'
[{"id":4002,"tag_name":"v2.0.0","name":"Current","created_at":"2026-07-26T10:00:00Z","draft":false,"prerelease":false},{"id":4001,"tag_name":"v1.0.0","name":"Previous","created_at":"2026-07-25T10:00:00Z","draft":false,"prerelease":false}]
JSON
          ;;
        'repos/acme/project/notifications?all=false&participating=false&per_page=100')
          if [[ "${MOCK_CI_EMPTY_NOTIFICATIONS:-0}" == "1" ]]; then
            printf '%s\n' '[]'
          elif [[ "${MOCK_CI_WRONG_NOTIFICATION_REPO:-0}" == "1" ]]; then
            cat <<'JSON'
[{"id":"5001","unread":true,"reason":"ci_activity","updated_at":"2026-07-26T10:00:00Z","subject":{"type":"CheckSuite","title":"CI failed"},"repository":{"full_name":"other/project"}}]
JSON
          else
            cat <<'JSON'
[{"id":"5001","unread":true,"reason":"ci_activity","updated_at":"2026-07-26T10:00:00Z","subject":{"type":"CheckSuite","title":"CI failed"},"repository":{"full_name":"acme/project"}}]
JSON
          fi
          ;;
        *)
          printf 'ci gh mock: unexpected GET endpoint: %s\n' "$endpoint" >&2
          exit 97
          ;;
      esac
      exit 0
    fi

    mutation_key="${method}:${endpoint}"
    case "$mutation_key" in
      'POST:repos/acme/project/actions/workflows/501/dispatches'|\
      'DELETE:repos/acme/project/actions/runs/1001'|\
      'POST:repos/acme/project/deployments/3001/statuses'|\
      'DELETE:repos/acme/project/deployments/3001'|\
      'DELETE:repos/acme/project/releases/4001'|\
      'PATCH:notifications/threads/5001')
        ;;
      *)
        printf 'ci gh mock: denied mutation: %s\n' "$mutation_key" >&2
        exit 97
        ;;
    esac

    if [[ -n "${MOCK_CI_MUTATION_FAIL:-}" \
      && "$mutation_key" == *"$MOCK_CI_MUTATION_FAIL"* ]]; then
      exit "${MOCK_CI_MUTATION_RC:-1}"
    fi
    ;;
  *)
    printf 'ci gh mock: unexpected subcommand: %s\n' "$subcommand" >&2
    exit 97
    ;;
esac
