# DT-MCP-Server
Dynatrace MCP Server setup and configuration

An MCP (Model Context Protocol) server setup that connects Copilot/Claude to a **Dynatrace** tenant, giving the AI assistant deep, correct knowledge of the Dynatrace Managed v2 REST API surface, so it goes straight to the right, narrowly-scoped API call instead of guessing.

Built on [dynatrace-oss/dynatrace-managed-mcp](https://github.com/dynatrace-oss/dynatrace-managed-mcp), which wraps 9 API domains as MCP tools, all against `{apiEndpointUrl}/e/{environmentId}/api/v2/...`.

## What's in this repo

- `.github/mcpclient-instructions.md` - Deep API v2 reference: endpoints, selector syntax, required/default params, response shapes, limits, and worked patterns for every domain below
- `.vscode/` - Editor and workspace settings
- `mcp.json` - MCP server registration for this workspace
- `dt-config.yaml` - Tenant connection config (do not commit real values, see Security below)
- `manage-dynatrace-mcp.ps1` - PowerShell script to start, stop, and manage the MCP server
- `manage-dynatrace-mcp.cmd` - cmd wrapper for the same script

## API domains covered by mcpclient-instructions.md

| Section | Domain |
|---|---|
| 1 | Topology (Entities / Smartscape) |
| 2 | Problems / incidents / root cause |
| 3 | Metrics / time series |
| 4 | Logs |
| 5 | Events |
| 6 | Vulnerabilities (Security Problems) |
| 7 | Config-change history (Audit Logs) |
| 8 | SLOs |
| 9 | Network zones |
| 10 | Pre-built multi-domain RCA / topology workflow, for questions that span more than one domain |

## Prerequisites

- A Dynatrace Managed tenant with API access
- An API token with the read scopes needed for the domains you use: `entities.read`, `problems.read`, `events.read`, `metrics.read`, `logs.read`, `securityProblems.read`, `auditLogs.read`, `slo.read`, `networkZones.read`
- VS Code with an MCP-compatible Copilot/Claude extension
- PowerShell on Windows (the management scripts are `.ps1` / `.cmd`)
- Nodejs pkg 20+ to run mcp service


## Setup

1. Clone this repo.
2. Open `dt-config.yaml` and fill in your tenant's `apiEndpointUrl`, `environmentId`, and token or credential fields locally. Do not commit this file with real values filled in, see Security below.
3. Start the MCP server from the VS Code terminal:

   ```
   .\manage-dynatrace-mcp.ps1 start
   ```

   Adjust this to the actual start command your script exposes.
4. Confirm `mcp.json` shows the server as connected in your Copilot/Claude client.

## Usage

Ask natural-language questions. Copilot/Claude will follow the workflow in the "How to use this file" section of `mcpclient-instructions.md` to pick the right domain(s) and build one correctly-scoped call. Examples:

- What's broken in production right now, and what's the root cause?
- What's the full dependency chain from `<service>` down to its host?
- Did our last deployment to `<service>` cause any problems in the following hour?
- What are our top open security problems by risk score?

