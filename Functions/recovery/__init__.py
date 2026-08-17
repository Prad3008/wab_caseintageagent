"""Function D recovery core — pure Python, no azure.functions imports.

The only thing outside this package should ever call is run_recovery().
Everything else (config, stuck_emails, publisher, service) is an internal
collaborator that run_recovery() wires together.
"""

from .service import run_recovery

__all__ = ["run_recovery"]
