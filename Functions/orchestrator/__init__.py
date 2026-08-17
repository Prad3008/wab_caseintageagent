"""orchestrator — stand-in for the real "Azure Function: orchestrate" (B.1-B.9).

DUMMY PACKAGE. Your teammate is building the real B.1-B.9 spine
(Case_Intake_Design_Diagram.png) as its own component. Until that lands,
this package gives recovery/ something real to call — every step logs what
it would do and returns a fake-but-shaped result, so the calling contract
(run_from_stage) is already correct and recovery doesn't need to change
when the real implementation replaces spine.py's insides.
"""

from .spine import run_from_stage

__all__ = ["run_from_stage"]
