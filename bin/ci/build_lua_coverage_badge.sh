#!/usr/bin/env bash
set -euo pipefail

REPORT_FILE="${1:-artifacts/coverage/luacov.report.out}"
COVERAGE_DIR="${COVERAGE_DIR:-artifacts/coverage}"
PAGES_DIR="${PAGES_DIR:-artifacts/pages}"
SUMMARY_FILE="${SUMMARY_FILE:-${COVERAGE_DIR}/coverage-summary.json}"
PAGES_SUMMARY_FILE="${PAGES_SUMMARY_FILE:-${PAGES_DIR}/coverage-summary.json}"
BADGE_FILE="${BADGE_FILE:-${PAGES_DIR}/coverage-badge.json}"
TOTAL_BADGE_FILE="${TOTAL_BADGE_FILE:-${PAGES_DIR}/coverage-total-badge.json}"
INDEX_FILE="${INDEX_FILE:-${PAGES_DIR}/index.html}"
BASELINE_URL="${BASELINE_URL:-https://fairvisor.github.io/edge/coverage-summary.json}"

if [[ ! -f "${REPORT_FILE}" ]]; then
  echo "coverage report not found: ${REPORT_FILE}" >&2
  exit 1
fi

mkdir -p "${COVERAGE_DIR}" "${PAGES_DIR}"

read -r total_hits total_missed total_coverage < <(
  awk '
    /^Total[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9.]+%$/ {
      gsub("%", "", $4)
      print $2, $3, $4
    }
  ' "${REPORT_FILE}" | tail -n 1
) || true

read -r non_generated_hits non_generated_missed non_generated_coverage < <(
  awk '
    BEGIN {
      hits = 0
      missed = 0
    }
    /^src\/fairvisor\// && $1 !~ /^src\/fairvisor\/generated\// {
      hits += $2
      missed += $3
    }
    END {
      total = hits + missed
      if (total == 0) {
        print "0 0 0.00"
      } else {
        printf "%d %d %.2f\n", hits, missed, (hits * 100) / total
      }
    }
  ' "${REPORT_FILE}"
) || true

if [[ -z "${total_coverage:-}" ]]; then
  echo "failed to parse total coverage from ${REPORT_FILE}" >&2
  exit 1
fi

coverage_color() {
  local coverage="$1"

  awk -v coverage="${coverage}" '
    BEGIN {
      if (coverage >= 95) {
        print "brightgreen"
      } else if (coverage >= 90) {
        print "green"
      } else if (coverage >= 80) {
        print "yellowgreen"
      } else if (coverage >= 70) {
        print "yellow"
      } else if (coverage >= 60) {
        print "orange"
      } else {
        print "red"
      }
    }
  '
}

resolve_baseline_coverage() {
  if [[ -n "${LUA_COVERAGE_MIN_NON_GENERATED:-}" ]]; then
    printf '%s\n' "${LUA_COVERAGE_MIN_NON_GENERATED}"
    return 0
  fi

  if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]]; then
    return 0
  fi

  local payload
  if ! payload="$(curl --fail --silent --show-error --location "${BASELINE_URL}" 2>/dev/null)"; then
    echo "baseline not found, skipping regression gate for bootstrap run: ${BASELINE_URL}" >&2
    return 0
  fi

  local baseline
  if ! baseline="$(
    printf '%s' "${payload}" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
    value = data["non_generated"]["coverage"]
except Exception:
    raise SystemExit(1)

print(value)
'
  )"; then
    echo "baseline could not be parsed, skipping regression gate: ${BASELINE_URL}" >&2
    return 0
  fi

  printf '%s\n' "${baseline}"
}

assert_minimum_coverage() {
  local actual="$1"
  local minimum="$2"
  local label="$3"

  if [[ -z "${minimum}" ]]; then
    return 0
  fi

  if awk -v actual="${actual}" -v minimum="${minimum}" 'BEGIN { exit !(actual + 1e-9 < minimum) }'; then
    echo "${label} coverage regression: ${actual}% < ${minimum}%" >&2
    exit 1
  fi
}

badge_json() {
  local label="$1"
  local message="$2"
  local color="$3"

  cat <<EOF
{
  "schemaVersion": 1,
  "label": "${label}",
  "message": "${message}",
  "color": "${color}"
}
EOF
}

updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
commit_sha="${GITHUB_SHA:-local}"
repo_name="${GITHUB_REPOSITORY:-fairvisor/edge}"
run_url=""

if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
  run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

baseline_non_generated_coverage="$(resolve_baseline_coverage)"

assert_minimum_coverage "${total_coverage}" "${LUA_COVERAGE_MIN_TOTAL:-}" "total"
assert_minimum_coverage "${non_generated_coverage}" "${baseline_non_generated_coverage:-}" "non-generated"

badge_json "lua coverage" "${non_generated_coverage}%" "$(coverage_color "${non_generated_coverage}")" > "${BADGE_FILE}"
badge_json "lua coverage total" "${total_coverage}%" "$(coverage_color "${total_coverage}")" > "${TOTAL_BADGE_FILE}"

cat > "${SUMMARY_FILE}" <<EOF
{
  "generated_at": "${updated_at}",
  "repository": "${repo_name}",
  "commit": "${commit_sha}",
  "run_url": "${run_url}",
  "total": {
    "hits": ${total_hits},
    "missed": ${total_missed},
    "coverage": ${total_coverage}
  },
  "non_generated": {
    "hits": ${non_generated_hits},
    "missed": ${non_generated_missed},
    "coverage": ${non_generated_coverage}
  }
}
EOF

cp "${SUMMARY_FILE}" "${PAGES_SUMMARY_FILE}"

cat > "${INDEX_FILE}" <<EOF
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Fairvisor Lua Coverage</title>
    <style>
      :root {
        color-scheme: light;
        --bg: #f6f7f3;
        --panel: #ffffff;
        --text: #182016;
        --muted: #5b6657;
        --line: #d8ddd2;
        --accent: #1e7a4f;
      }
      body {
        margin: 0;
        background: linear-gradient(180deg, #eef4ea 0%, var(--bg) 100%);
        color: var(--text);
        font: 16px/1.5 "Georgia", "Times New Roman", serif;
      }
      main {
        max-width: 820px;
        margin: 0 auto;
        padding: 48px 20px 64px;
      }
      h1 {
        margin: 0 0 12px;
        font-size: 2.4rem;
      }
      p {
        margin: 0 0 18px;
        color: var(--muted);
      }
      .grid {
        display: grid;
        gap: 16px;
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        margin: 28px 0;
      }
      .card {
        background: var(--panel);
        border: 1px solid var(--line);
        border-radius: 18px;
        padding: 20px;
        box-shadow: 0 12px 30px rgba(24, 32, 22, 0.06);
      }
      .metric {
        font-size: 2rem;
        color: var(--accent);
      }
      code {
        font-family: "SFMono-Regular", "Consolas", monospace;
        font-size: 0.95em;
      }
      a {
        color: var(--accent);
      }
    </style>
  </head>
  <body>
    <main>
      <h1>Fairvisor Lua Coverage</h1>
      <p>Coverage is generated by <code>luacov</code> in CI. The badge in README uses the non-generated metric so autogenerated tables do not mask regressions in handwritten runtime code.</p>
      <div class="grid">
        <section class="card">
          <div>Total coverage</div>
          <div class="metric">${total_coverage}%</div>
          <div>${total_hits} hits / ${total_missed} missed</div>
        </section>
        <section class="card">
          <div>Non-generated coverage</div>
          <div class="metric">${non_generated_coverage}%</div>
          <div>${non_generated_hits} hits / ${non_generated_missed} missed</div>
        </section>
      </div>
      <p>Generated at <code>${updated_at}</code> for commit <code>${commit_sha}</code>.</p>
      <p><a href="coverage-badge.json">coverage-badge.json</a> | <a href="coverage-total-badge.json">coverage-total-badge.json</a> | <a href="coverage-summary.json">coverage-summary.json</a></p>
    </main>
  </body>
</html>
EOF

echo "total coverage: ${total_coverage}%"
echo "non-generated coverage: ${non_generated_coverage}%"
if [[ -n "${baseline_non_generated_coverage:-}" ]]; then
  echo "baseline non-generated coverage: ${baseline_non_generated_coverage}%"
fi
