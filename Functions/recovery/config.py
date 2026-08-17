"""Configuration for the Function D recovery service.

Centralises env-var reads so the rest of the package stays pure Python —
no os.environ calls scattered through business logic, which is what makes
service.py testable offline.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

# Fallback used only when SQL_CONNECTION_STRING is not set in the environment.
# ActiveDirectoryInteractive pops a browser login, so this default is only
# viable for a human running this locally (e.g. local_run.py) — never for the
# deployed Timer-triggered Function, which has no one to click through a
# login prompt. The deployed Function must have SQL_CONNECTION_STRING set as
# an app setting using Authentication=ActiveDirectoryMsi instead (see
# deploy notes / func_recovery app settings).
_DEFAULT_SQL_CONNECTION_STRING = (
    "Data Source=sql-zenon-wab-wus2.database.windows.net;"
    "Initial Catalog=sqldb-case-intake-dev;"
    "Persist Security Info=False;"
    "User ID=pgoyal@zenon.ai;"
    "Pooling=False;"
    "MultipleActiveResultSets=False;"
    "Encrypt=True;"
    "TrustServerCertificate=False;"
    "Authentication=ActiveDirectoryInteractive;"
    'Application Name="SQL Server Management Studio";'
    "Command Timeout=0"
)

# Maps the .NET SqlClient connection-string keywords (Data Source, Initial
# Catalog, ...) that SSMS/the app's own connection string uses to the ODBC
# keywords pyodbc's driver manager actually understands (Server, Database,
# ...). Without this translation pyodbc fails immediately with "Data source
# name not found" — .NET and ODBC connection strings look similar but are not
# interchangeable. Keys not listed here (Persist Security Info, Pooling,
# MultipleActiveResultSets, Command Timeout — all .NET ADO.NET-level
# concepts with no ODBC connection-string equivalent) are dropped rather than
# passed through, since an unrecognized ODBC keyword is a connection error,
# not a no-op.
_DOTNET_TO_ODBC_KEYS = {
    "data source": "Server",
    "server": "Server",
    "initial catalog": "Database",
    "database": "Database",
    "user id": "UID",
    "uid": "UID",
    "password": "PWD",
    "pwd": "PWD",
    "application name": "APP",
    "encrypt": "Encrypt",
    "trustservercertificate": "TrustServerCertificate",
    "authentication": "Authentication",
}
_BOOL_NORMALIZE = {"true": "yes", "false": "no"}
_ODBC_DRIVER = "ODBC Driver 18 for SQL Server"


def _to_odbc_connection_string(raw: str) -> str:
    """Translates a .NET-style connection string to one pyodbc can use.

    A no-op (returned unchanged) if `raw` already declares an ODBC Driver=,
    so a caller who already hands us a proper ODBC string isn't mangled.
    """
    if "driver=" in raw.lower():
        return raw

    odbc_parts: dict[str, str] = {}
    for chunk in raw.split(";"):
        chunk = chunk.strip()
        if not chunk or "=" not in chunk:
            continue
        key, _, value = chunk.partition("=")
        key = key.strip().lower()
        value = value.strip().strip('"')
        odbc_key = _DOTNET_TO_ODBC_KEYS.get(key)
        if odbc_key is None:
            continue
        if odbc_key in ("Encrypt", "TrustServerCertificate"):
            value = _BOOL_NORMALIZE.get(value.lower(), value)
        odbc_parts[odbc_key] = value

    odbc_parts.setdefault("Encrypt", "yes")
    odbc_parts.setdefault("TrustServerCertificate", "no")

    rendered = ";".join(f"{k}={v}" for k, v in odbc_parts.items())
    return f"Driver={{{_ODBC_DRIVER}}};{rendered}"


# status_code values that dbo.cia_email_instance.status_description treats as
# a recorded terminal outcome (6 = posted to CRM, 8 = no case needed, 9 =
# processing failed, 10 = failed/no retry attempted). Part A only replays
# rows NOT in this set — i.e. rows that stopped making progress mid-pipeline
# without ever recording a terminal outcome. ASSUMPTION, confirmed against
# schema on 2026-08-07 but not against a documented product spec: treat a
# recorded "Processing failed" (9) as terminal-for-recovery-purposes (already
# handled by the app's own failure path), not as "stuck". Adjust via
# RECOVERY_TERMINAL_STATUS_CODES if that's wrong.
_DEFAULT_TERMINAL_STATUS_CODES = (6, 8, 9, 10)


@dataclass(frozen=True)
class RecoveryConfig:
    """Runtime settings for a single recovery run.

    Attributes:
        sql_connection_string: Azure SQL connection string. The deployed
            Function should set this via ActiveDirectoryMsi (managed
            identity); local/manual runs may use the ActiveDirectoryInteractive
            default below.
        service_bus_namespace: e.g. "<namespace>.servicebus.windows.net".
            None means Service Bus is not wired up yet — run_recovery() then
            uses a log-only publisher instead of a real one (no queue exists
            for a recovered message to land on yet).
        queue_name: the pipeline's ingestion queue. Only used if
            service_bus_namespace is also set.
        write_window_minutes: how long a row may sit at a non-terminal
            status before the scan treats it as stuck.
        terminal_status_codes: cia_email_instance.status_code values that
            count as a recorded terminal outcome (success or failure) —
            the scan never touches rows already at one of these.
        max_retry_attempts: a stuck row already at this many attempts is
            never retried again — stops a persistently-failing activity_id
            from generating a new attempt row forever.
    """

    sql_connection_string: str
    service_bus_namespace: str | None = None
    queue_name: str | None = None
    write_window_minutes: int = 10
    terminal_status_codes: tuple[int, ...] = field(default_factory=lambda: _DEFAULT_TERMINAL_STATUS_CODES)
    max_retry_attempts: int = 5

    @classmethod
    def from_env(cls) -> "RecoveryConfig":
        """Builds config from Function App settings / local environment."""
        raw_connection_string = os.environ.get("SQL_CONNECTION_STRING") or _DEFAULT_SQL_CONNECTION_STRING
        sql_connection_string = _to_odbc_connection_string(raw_connection_string)

        terminal_codes_raw = os.environ.get("RECOVERY_TERMINAL_STATUS_CODES")
        terminal_status_codes = (
            tuple(int(code.strip()) for code in terminal_codes_raw.split(",") if code.strip())
            if terminal_codes_raw
            else _DEFAULT_TERMINAL_STATUS_CODES
        )

        return cls(
            sql_connection_string=sql_connection_string,
            service_bus_namespace=os.environ.get("SERVICE_BUS_NAMESPACE") or None,
            queue_name=os.environ.get("SERVICE_BUS_QUEUE_NAME") or None,
            write_window_minutes=int(os.environ.get("RECOVERY_WRITE_WINDOW_MINUTES", "10")),
            terminal_status_codes=terminal_status_codes,
            max_retry_attempts=int(os.environ.get("RECOVERY_MAX_RETRY_ATTEMPTS", "5")),
        )
