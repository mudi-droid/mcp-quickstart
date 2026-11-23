# DataRobot MCP server — quickstart

One command to go from nothing to a running MCP server you can point Cursor or Claude at.

```bash
./setup.sh
```

It installs the DataRobot CLI if missing, clones
[`datarobot-mcp-template`](https://github.com/datarobot-community/datarobot-mcp-template),
writes a working `.env`, and installs dependencies. No secrets are printed, and it is safe
to re-run.

## Before you run it

**Credentials.** In a Codespace they are already injected. On a laptop, log in once:

```bash
dr auth set-url && dr auth login
```

Use your own DataRobot URL — it is not always `app.datarobot.com`.

**Ports, if you are in a Codespace.** Expose these when you *create* the session; they
cannot be added afterwards.

| Port | For |
|---|---|
| 8080 | the MCP server |
| 8090 | Build Studio |

## Start it

```bash
cd datarobot-mcp-template
task dev
```

Expect a banner reading `34 tools, 0 prompts, 0 resources`. Build Studio starts alongside it
on `http://127.0.0.1:8090` and stops with it.

> **Run from the repo root, not from `dr_mcp/`.** Only the root `Taskfile.yaml` loads `.env`,
> so starting from inside `dr_mcp/` gives you a healthy-looking banner with **0 tools**.

Ask the server questions in plain English:

```bash
task dr_mcp:test-interactive
```

It starts its own server on 8082, so it does not matter whether `task dev` is running.

> **`MODEL` ships blank and you must set it.** The agent test fails with `'model' is required`
> until you do. Nothing is chosen for you, because the valid ids differ per install — a
> Bedrock-only tenant has none of the names a SaaS one has.

```bash
dr llm-gateway list          # the ids valid on this install
```

Put your choice in `MODEL=` at the bottom of `.env`.

Deploy it into DataRobot:

```bash
task deploy                  # do not pipe or redirect this command
```

On a **laptop**, log in to a local Pulumi backend once first:

```bash
pulumi login --local
```

⚠ **Not in a Codespace.** `PULUMI_BACKEND_URL` is already set there to `~/storage`, the
volume that persists between sessions. `pulumi login --local` repoints it at `~`, which does
not — so stack state can disappear and `task destroy` will not find what you deployed. Check
with `pulumi whoami --verbose`; restore with `pulumi login file://~/storage`.

## Configuring it

Everything lives in `.env`, which survives regenerating the Taskfiles. Two worth knowing:

- **`MCP_CLI_CONFIGS`** — which tool groups are on. The script sets `predictive`; use `""`
  for none, or a comma-separated list.
- **`DR_EXPERIMENT_*`** — which Build Studio tabs appear. The script enables MCP Servers,
  Managed MCP, Assist, Entities and Memory. The rest are listed commented out in the file.

`.env.template` carries the same options, all commented, so a regenerated `.env` still
documents them. `dr xp --help` has the full list.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Banner shows `0 tools` | Started from `dr_mcp/` instead of the repo root. |
| Auth fails in a Codespace | Credentials come from the environment, not `.env`. Check `dr auth check`. |
| Auth fails on a laptop | A stale `DATAROBOT_API_TOKEN` in your shell. `unset` it and re-run. |
| `task dr_mcp:test-interactive` times out | `MCP_SERVER_PORT` is set. It binds 8082 — leave that line commented. |
| `No Taskfile found` | You are above the repo. `cd datarobot-mcp-template` first. |
| `task test-interactive` does not exist | From the root it is namespaced: `task dr_mcp:test-interactive`. |
| `task deploy` will not pick a stack | It was piped or redirected. Run it plainly. |
| Pulumi warns about `PULUMI_BACKEND_URL` | You ran `pulumi login --local` in a Codespace. See above. |
| `'model' is required` | No `MODEL` set. Uncomment one at the bottom of `.env`. |
| `dr` behaves oddly | A second `dr` on your PATH. Check with `which -a dr`. |

## Connecting a client

In `~/.cursor/mcp.json`, or your client's MCP config:

```json
{
  "mcpServers": {
    "datarobot": {
      "url": "https://<your-datarobot-host>/api/v2/genai/globalmcp/mcp",
      "headers": { "Authorization": "Bearer ${env:DATAROBOT_API_TOKEN}" }
    }
  }
}
```

A server you deployed yourself needs a second header as well:

```json
"headers": {
  "Authorization": "Bearer ${env:DATAROBOT_API_TOKEN}",
  "x-datarobot-api-key": "${env:DATAROBOT_API_TOKEN}"
}
```
