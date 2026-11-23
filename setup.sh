#!/usr/bin/env bash
# DataRobot MCP server -- one-command setup.
# Installs the CLI, clones the MCP template, writes a working .env, installs deps.
# Works on a laptop or in a DataRobot Codespace. Safe to re-run. Prints no secrets.
#
#   ./setup.sh [target-directory]

set -euo pipefail

REPO="https://github.com/datarobot-community/datarobot-mcp-template.git"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

# Validate the exact token we are about to use. `dr auth check` deliberately checks the
# credentials STORED by `dr auth login`, not the ones in the environment, so it will
# happily pass while a stale DATAROBOT_API_TOKEN is the thing we are about to write.
# Random hex, portable. openssl is NOT present in a DataRobot Codespace image, and
# Python is not guaranteed on a bare laptop -- so try all three.
rand_hex() {  # $1 = number of bytes
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import os,binascii,sys;print(binascii.hexlify(os.urandom(int(sys.argv[1]))).decode())" "$1"
  elif [ -r /dev/urandom ]; then
    od -An -tx1 -N "$1" /dev/urandom | tr -d ' \n'; echo
  else
    return 1
  fi
}

token_works() {  # $1 = token, $2 = endpoint (…/api/v2)
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  curl -fsS -m 20 -o /dev/null -H "Authorization: Bearer $1" "${2%/}/account/info/" 2>/dev/null
}

# A DataRobot Codespace runs as the 'notebooks' user. Detect it once, up front:
# it changes where we clone AND how credentials are resolved.
IN_CODESPACE=0
if [ "$(id -un 2>/dev/null)" = "notebooks" ] || [ -d /home/notebooks ]; then
  IN_CODESPACE=1
fi

# Codespaces persist work under ~/storage. Everywhere else, clone into the current
# directory so nothing appears in $HOME that the user did not ask for.
if [ -n "${1:-}" ]; then
  TARGET="$1"
elif [ "$IN_CODESPACE" -eq 1 ]; then
  TARGET="$HOME/storage/datarobot-mcp-template"
else
  TARGET="$PWD/datarobot-mcp-template"
fi

# ------------------------------------------------------------------- 1. CLI
say "Checking the DataRobot CLI"
if command -v dr >/dev/null 2>&1; then
  echo "    found: $(dr self version 2>/dev/null | tail -1 || echo 'version unknown')"
  if [ "$(command -v -a dr 2>/dev/null | wc -l | tr -d ' ')" -gt 1 ]; then
    warn "More than one 'dr' on PATH -- the first wins:"
    command -v -a dr | sed 's/^/        /'
    warn "Remove the stale one if commands misbehave ('dr self update' does not fix it)."
  fi
else
  echo "    not found -- installing"
  curl -fsSL https://cli.datarobot.com/install | sh
  command -v dr >/dev/null 2>&1 || die "Installed, but 'dr' is not on PATH. Open a new shell and re-run."
fi

# ----------------------------------------------------------- 2. credentials
say "Checking credentials"
if [ "$IN_CODESPACE" -eq 1 ]; then
  echo "    Codespace detected -- it injects credentials, so .env is left blank on purpose"
  echo "    (Task does not let .env override the environment, so the injected values win)"
else
  # Resolution order: this shell -> the login stored by 'dr auth login' -> stop and ask.
  # 'dr auth export' only prints shell statements and never starts a login flow, so
  # eval-ing it is safe. Nothing is echoed, so no token reaches the screen.
  TOKEN_FROM_SHELL=0
  if [ -n "${DATAROBOT_API_TOKEN:-}" ]; then
    TOKEN_FROM_SHELL=1
    echo "    using the token set in this shell"
  else
    eval "$(dr auth export --shell bash 2>/dev/null || true)"
  fi

  # Resolve the endpoint before validating -- the token alone proves nothing.
  if [ -z "${DATAROBOT_ENDPOINT:-}" ]; then
    DATAROBOT_ENDPOINT="$(dr auth export --shell bash 2>/dev/null \
      | sed -n 's/^export DATAROBOT_ENDPOINT=//p;s/^DATAROBOT_ENDPOINT=//p' \
      | tr -d "\"'" | head -1)"
  fi

  # Credentials can exist and still be dead -- a rotated token is the common case.
  if [ -n "${DATAROBOT_API_TOKEN:-}" ] && ! token_works "$DATAROBOT_API_TOKEN" "${DATAROBOT_ENDPOINT:-}"; then
    warn "Those credentials were rejected by ${DATAROBOT_ENDPOINT:-DataRobot} (rotated or expired)."
    unset DATAROBOT_API_TOKEN
    # A dead token exported in the shell shadows a perfectly good stored login.
    if [ "$TOKEN_FROM_SHELL" -eq 1 ]; then
      warn "That token came from this shell, not from 'dr auth login'. Trying your stored login."
      unset DATAROBOT_ENDPOINT
      eval "$(dr auth export --shell bash 2>/dev/null || true)"
      if token_works "${DATAROBOT_API_TOKEN:-}" "${DATAROBOT_ENDPOINT:-}"; then
        echo "    stored login is valid -- using it"
        echo "    (unset DATAROBOT_API_TOKEN in your shell to stop it shadowing this)"
      else
        unset DATAROBOT_API_TOKEN DATAROBOT_ENDPOINT
      fi
    fi
  fi

  # The probes below run with these values exported, so the server and the CLI see the
  # same credentials the script just verified.
  export DATAROBOT_API_TOKEN DATAROBOT_ENDPOINT 2>/dev/null || true

  # 'dr auth login' is deliberately NOT run from inside this script: it does not
  # reliably hand control back when called non-interactively, and a script that hangs
  # on a first run is worse than one that asks for a second command.
  if [ -z "${DATAROBOT_API_TOKEN:-}" ]; then
    if [ "$TOKEN_FROM_SHELL" -eq 1 ]; then
      die "The DATAROBOT_API_TOKEN in this shell was rejected, with no valid stored login to fall back on.
  If it is stale, drop it and re-run:    unset DATAROBOT_API_TOKEN && ./setup.sh
  Otherwise log in and re-run:           dr auth set-url && dr auth login"
    fi
    die "No valid DataRobot credentials.
  Log in (this opens your browser), then run this script again:

      dr auth set-url     # your own DataRobot URL -- it is not always app.datarobot.com
      dr auth login"
  fi

  # A token exported in the shell often arrives without an endpoint. Fill it from the
  # CLI's own config rather than failing -- but still never invent one.
  if [ -z "${DATAROBOT_ENDPOINT:-}" ]; then
    DATAROBOT_ENDPOINT="$(dr auth export --shell bash 2>/dev/null \
      | sed -n 's/^export DATAROBOT_ENDPOINT=//p;s/^DATAROBOT_ENDPOINT=//p' \
      | tr -d "\"'" | head -1)"
    export DATAROBOT_ENDPOINT
  fi

  # Never guess the endpoint. Tenants differ (app.datarobot.com, EU, STS, self-hosted),
  # and a wrong one authenticates against someone else's install or fails obscurely.
  [ -n "${DATAROBOT_ENDPOINT:-}" ] || die \
    "Credentials found, but no DataRobot endpoint with them.

  Set the URL for your DataRobot install, then re-run:

      dr auth set-url"
  echo "    endpoint: ${DATAROBOT_ENDPOINT}"
fi

# ------------------------------------------------------------------ 3. repo
say "Fetching the MCP template"
if [ -d "$TARGET/.git" ]; then
  echo "    already present at $TARGET"
else
  mkdir -p "$(dirname "$TARGET")"
  git clone --quiet "$REPO" "$TARGET"
  echo "    cloned to $TARGET"
fi
cd "$TARGET"

# ------------------------------------------------------------------- 4. env
say "Writing .env"
if [ -f .env ]; then
  warn ".env already exists -- leaving it alone. Delete it and re-run to regenerate."
else
  [ -f .env.template ] || die "No .env.template in the repo. Did the clone succeed?"

  # Document the same options in .env.template, fully commented. A .env regenerated
  # from the template is then inert but self-describing, instead of silently losing
  # every Build Studio setting.
  if ! grep -q 'DR_EXPERIMENT_ENABLE_MCP_SERVERS' .env.template; then
    cat >> .env.template <<'XPTPL'

# --- Build Studio (dr xp) -------------------------------------------------
# `task dev` starts Build Studio in the background and stops it with the server.
# Not needed to build or test an MCP server -- `task test-interactive` does that.
# Every `dr xp` flag has an env var; the root Taskfile loads this file, so setting
# one here is all it takes. Ports default to 8090 (Studio) and 4099 (Assist).
# Uncomment what you want. Full list and defaults:  dr xp --help

# DR_EXPERIMENT_ENABLE_MCP_SERVERS=true    # every MCP server on the instance + its tools
# DR_EXPERIMENT_ENABLE_MANAGED_MCP=true    # the platform's own server and its tool sets
# DR_EXPERIMENT_ENABLE_ASSIST=true         # OpenCode coding assistant (on by default)
# DR_EXPERIMENT_ENABLE_ENTITIES=true       # switch which use case / deployment is in scope
# DR_EXPERIMENT_ENABLE_MEMORY=true         # agent memory spaces
# DR_EXPERIMENT_ENABLE_CONNECTORS=true     # external OAuth connectors
# DR_EXPERIMENT_ENABLE_BYO_MCP=true        # register an MCP server DataRobot does not host
# DR_EXPERIMENT_ENABLE_EVALUATION=true     # preview; needs an evaluation component present
# DR_EXPERIMENT_ENABLE_METRICS=true        # OpenTelemetry metrics; empty until configured
# DR_EXPERIMENT_ENABLE_LOGS_RAW_VIEW=true  # terminal-style raw log view
# DR_EXPERIMENT_PORT=8090                  # change if 8090 is taken or not exposed

# MCP_CLI_CONFIGS=predictive               # which tool groups to enable; "" for none

# --- Agent model ----------------------------------------------------------
# Required by `task dr_mcp:test-interactive`. Set it in .env -- there is no default,
# and the valid ids differ per install. See what this one offers:
#   dr llm-gateway list
MODEL=
XPTPL
  fi

  # Copy AFTER documenting the template, so .env inherits MODEL= and the commented
  # options instead of being created from an older copy of the file.
  cp .env.template .env

  SECRET="$(rand_hex 64)"    || die "No way to generate a random secret (needs openssl, python3 or /dev/urandom)."
  PASSPHRASE="$(rand_hex 16)" || die "No way to generate a random secret (needs openssl, python3 or /dev/urandom)."

  # macOS sed and GNU sed disagree about -i, so rewrite via a temp file.
  set_var() {
    local key="$1" val="$2"
    if grep -qE "^#?[[:space:]]*${key}=" .env; then
      awk -v k="$key" -v v="$val" \
        'BEGIN{FS=OFS="="} $0 ~ "^#?[[:space:]]*"k"=" {print k"="v; next} {print}' \
        .env > .env.tmp && mv .env.tmp .env
    else
      printf '%s=%s\n' "$key" "$val" >> .env
    fi
  }

  set_var SESSION_SECRET_KEY       "$SECRET"
  set_var PULUMI_CONFIG_PASSPHRASE "$PASSPHRASE"
  set_var MCP_CLI_CONFIGS          "predictive"

  if [ "$IN_CODESPACE" -eq 1 ]; then
    set_var DATAROBOT_API_TOKEN ""
    set_var DATAROBOT_ENDPOINT  ""
  else
    set_var DATAROBOT_API_TOKEN "$DATAROBOT_API_TOKEN"
    set_var DATAROBOT_ENDPOINT  "$DATAROBOT_ENDPOINT"
  fi

  # The template's test harness binds 8082. Pinning a port here makes
  # `task test-interactive` time out, so keep it commented: documented, not set.
  if grep -qE '^MCP_SERVER_PORT=' .env; then
    awk '/^MCP_SERVER_PORT=/{print "#"$0; next}{print}' .env > .env.tmp && mv .env.tmp .env
  elif ! grep -qE '^#[[:space:]]*MCP_SERVER_PORT=' .env; then
    printf '\n# MCP_SERVER_PORT=8080   # leave unset: task test-interactive binds 8082\n' >> .env
  fi

  # `task dev` also starts Build Studio (dr xp) in the background and stops it with the
  # server. By default it binds 8090 with the MCP tabs OFF, which are the interesting
  # ones. Every dr xp flag has an env var, and the root Taskfile loads this file, so
  # setting them here configures Build Studio with no extra command.
  if ! grep -q '^DR_EXPERIMENT_ENABLE_MCP_SERVERS=' .env; then
    cat >> .env <<'XPENV'

# --- Build Studio (dr xp) -------------------------------------------------
# `task dev` starts Build Studio in the background alongside the MCP server and
# stops it with the server. You do not need it to build or test an MCP server --
# `task test-interactive` does that from the terminal. It is there when you want
# to see what exists on the instance.
#
# Every `dr xp` flag has an env var, and the root Taskfile loads this file, so
# these configure it with no extra command. Ports keep their defaults:
# Build Studio on 8090, OpenCode (Assist) on 4099.

DR_EXPERIMENT_ENABLE_MCP_SERVERS=true    # every MCP server on the instance + its tools
DR_EXPERIMENT_ENABLE_MANAGED_MCP=true    # the platform's own server and its tool sets
DR_EXPERIMENT_ENABLE_ASSIST=true         # OpenCode coding assistant (on by default)
DR_EXPERIMENT_ENABLE_ENTITIES=true       # switch which use case / deployment is in scope
DR_EXPERIMENT_ENABLE_MEMORY=true         # agent memory spaces

# Off by default. Turn on as needed:
# DR_EXPERIMENT_ENABLE_CONNECTORS=true    # external OAuth connectors
# DR_EXPERIMENT_ENABLE_BYO_MCP=true       # register an MCP server DataRobot does not host
# DR_EXPERIMENT_ENABLE_EVALUATION=true    # preview; needs an evaluation component present
# DR_EXPERIMENT_ENABLE_METRICS=true       # OpenTelemetry metrics; empty until configured
# DR_EXPERIMENT_ENABLE_LOGS_RAW_VIEW=true # terminal-style raw log view
# DR_EXPERIMENT_PORT=8090                 # change if 8090 is taken or not exposed
#
# Full list and defaults:  dr xp --help
XPENV
  fi

  echo "    .env written (secrets generated, never printed)"
  echo "    Build Studio flags written to .env (it runs in the background under task dev)"
  echo "    optional: set DATAROBOT_DEFAULT_USE_CASE in .env to deploy into an existing use case"
  warn "ACTION NEEDED: MODEL is blank in .env. Set it before the agent test (dr llm-gateway list)."
fi

# --------------------------------------------------------------- 5. install
say "Installing dependencies"
if command -v task >/dev/null 2>&1; then
  task install
else
  warn "'task' not found -- install go-task, then run: task install"
fi

# ------------------------------------------- 6. Build Studio plugin (optional)
say "Checking the Build Studio plugin (dr xp)"
# Probes close stdin and skip the plugin update check. With output redirected an
# interactive prompt is invisible and the script merely appears to hang -- the same
# trap that makes a piped `task deploy` refuse to run.
# Ask the plugin registry, never the plugin. Running `dr xp` inside a project
# directory starts Build Studio (and the dev stack with it) -- not something a
# probe may do.
if dr plugin list </dev/null 2>/dev/null | grep -qE '(^|[^a-z])xp([^a-z]|$)'; then
  echo "    available"
else
  # `task dev` runs `dr xp` itself, so a missing plugin breaks it. Install rather than
  # report. Not `dr build-studio -y`: that installs AND opens the dashboard, and a setup
  # script must not start a server. stdin is closed so a prompt can never hang us.
  echo "    not installed -- installing (task dev needs it)"
  ok=1
  for plug in xp opencode; do
    dr plugin install "$plug" </dev/null >/dev/null 2>&1 || ok=0
  done
  if [ "$ok" -eq 1 ]; then
    echo "    installed xp and opencode"
  else
    warn "Could not install the Build Studio plugins. The MCP server still works;"
    warn "to fix it later, run:  dr build-studio -y"
  fi
fi

# ---------------------------------------------------------------- 7. verify
say "Verifying authentication"
if dr --skip-plugin-update-check llm-gateway list </dev/null >/dev/null 2>&1; then
  echo "    OK -- the LLM Gateway answered"
else
  warn "Could not reach the LLM Gateway. Check with: dr auth check"
fi

cat <<DONE

Done. From ${TARGET}:

  task dev                     # start the server  -- run from the repo ROOT, not dr_mcp/
  task dr_mcp:test-interactive # talk to it with an agent (namespaced from the root)

  BEFORE that one works, set MODEL in .env -- it ships blank, on purpose:

      dr llm-gateway list        # the ids valid on THIS install
      MODEL=<id>                 # edit .env

  Only the root Taskfile loads .env. Running these from dr_mcp/ starts a server with
  no credentials and 0 tools.

  task deploy                  # deploy it  -- do NOT pipe or redirect this command

  On a laptop, log in to a local Pulumi backend once first:  pulumi login --local
  In a Codespace do NOT: PULUMI_BACKEND_URL is already set to ~/storage (the volume
  that persists). `pulumi login --local` repoints it at ~, which does not.

task dev also starts Build Studio for you, and stops it with the server:

  http://127.0.0.1:8090      MCP Servers + Managed MCP tabs are enabled in .env

  In a Codespace, expose 8080 and 8090 BEFORE the session starts -- ports
  cannot be added afterwards.

DONE
