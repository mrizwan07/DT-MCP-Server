param(
    [ValidateSet('status','start','start-foreground','stop','restart')]
    [string]$Action = 'status',
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'dt-config.yaml'),
    [string]$LogFile = (Join-Path $PSScriptRoot 'dynatrace-managed-mcp.log')
)

$ErrorActionPreference = 'Stop'

function Get-McpProcesses {
    return Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match 'node|npx' -and (
                $_.CommandLine -match 'dynatrace-managed-mcp-server' -or
                $_.CommandLine -match '@dynatrace-oss' -or
                $_.CommandLine -match 'dynatrace-managed-mcp'
            )
        }
}

function Test-ConfigExists {
    if (-not (Test-Path $ConfigFile)) {
        throw "Dynatrace config file not found: $ConfigFile"
    }
}

function Start-McpServer {
    Test-ConfigExists

    $existing = Get-McpProcesses
    if ($existing) {
        Write-Host "Dynatrace MCP server is already running."
        foreach ($p in $existing) {
            Write-Host "PID: $($p.ProcessId) | Command: $($p.CommandLine)"
        }
        return
    }

    $env:DT_CONFIG_FILE = $ConfigFile
    $env:LOG_LEVEL = 'info'

    # Ensure Node uses the system trust store so TLS to Dynatrace Managed validates correctly
    $env:NODE_OPTIONS = '--use-system-ca'

    # WARNING: The following disables TLS verification for Node child processes started by this script.
    # This is insecure and should only be used temporarily for debugging. It will allow the MCP server
    # to connect even when the Dynatrace certificate chain is not trusted by the OS.
    $env:NODE_TLS_REJECT_UNAUTHORIZED = '0'
    Write-Host "Warning: NODE_TLS_REJECT_UNAUTHORIZED=0 (TLS verification disabled) for MCP server process"

    # Try to persist NODE_OPTIONS (Machine scope if possible, otherwise User scope); not fatal if it fails
    try {
        [Environment]::SetEnvironmentVariable('NODE_OPTIONS','--use-system-ca','Machine')
        Write-Host "Persisted NODE_OPTIONS=--use-system-ca at Machine scope"
    } catch {
        try {
            [Environment]::SetEnvironmentVariable('NODE_OPTIONS','--use-system-ca','User')
            Write-Host "Persisted NODE_OPTIONS=--use-system-ca at User scope"
        } catch {
            Write-Host "Unable to persist NODE_OPTIONS; using it for this session only"
        }
    }

    # Use cmd.exe to run npx with shell-style redirection so stdout and stderr can be appended to the same log file
    $cmd = 'npx.cmd -y @dynatrace-oss/dynatrace-managed-mcp-server@latest'
    $escapedLog = $LogFile.Replace('"', '"')
    $arg = "/c $cmd >> `"$escapedLog`" 2>>&1"
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList $arg -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle Hidden

    Write-Host "Started Dynatrace MCP server."
    Write-Host "PID: $($proc.Id)"
    Write-Host "Config: $ConfigFile"
    Write-Host "Log: $LogFile"
}

function Stop-McpServer {
    $procs = Get-McpProcesses
    if (-not $procs) {
        Write-Host "Dynatrace MCP server is not running."
        return
    }

    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.ProcessId -Force
            Write-Host "Stopped Dynatrace MCP server (PID $($p.ProcessId))."
        }
        catch {
            Write-Host "Failed to stop PID $($p.ProcessId): $($_.Exception.Message)"
        }
    }
}

function Get-McpStatus {
    $procs = Get-McpProcesses
    if (-not $procs) {
        Write-Host "Dynatrace MCP server is not running."
        exit 1
    }

    Write-Host "Dynatrace MCP server is running."
    foreach ($p in $procs) {
        Write-Host "PID: $($p.ProcessId) | Command: $($p.CommandLine)"
    }
    exit 0
}

function Start-McpServerForeground {
    Test-ConfigExists

    $existing = Get-McpProcesses
    if ($existing) {
        Write-Host "Dynatrace MCP server is already running."
        foreach ($p in $existing) {
            Write-Host "PID: $($p.ProcessId) | Command: $($p.CommandLine)"
        }
        return
    }

    $env:DT_CONFIG_FILE = $ConfigFile
    $env:LOG_LEVEL = 'info'

    # Use system CA if possible
    $env:NODE_OPTIONS = '--use-system-ca'

    # WARNING: The following disables TLS verification for Node child processes started by this script.
    # This is insecure and should only be used temporarily for debugging.
    $env:NODE_TLS_REJECT_UNAUTHORIZED = '0'
    Write-Host "Warning: NODE_TLS_REJECT_UNAUTHORIZED=0 (TLS verification disabled) for MCP server process"

    Write-Host "Starting Dynatrace MCP server in foreground. This will run in this console and block until you stop it (Ctrl+C)."
    Set-Location $PSScriptRoot

    & npx -y @dynatrace-oss/dynatrace-managed-mcp-server@latest
}

switch ($Action) {
    'status' { Get-McpStatus }
    'start' { Start-McpServer }
    'start-foreground' { Start-McpServerForeground }
    'stop' { Stop-McpServer }
    'restart' {
        Stop-McpServer
        Start-Sleep -Seconds 2
        Start-McpServer
    }
}
