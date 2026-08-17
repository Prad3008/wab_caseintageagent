"""Dummy stand-in for the real case-intake orchestrator (B.1-B.9).

Mirrors Case_Intake_Design_Diagram.png: Write Activity ID (B.1) -> Write
queue-item (B.2) -> was the write successful? (B.3) -> pull email data from
Dataverse (B.4) -> parse email to text (B.5) -> invoke the agent workflow
(B.6) -> is it actionable and is the agent confident? (B.7) -> build the
payload (B.8) -> POST it (B.9).

Every step here is a placeholder: it logs what it would do and returns a
fake-but-correctly-shaped result. Your teammate's real implementation
replaces the bodies of the _b1.._b9 functions; run_from_stage's sequencing
(which steps to run/skip based on where a resumed attempt left off) is the
part recovery/ actually depends on, so that contract is real already.

resume_from_stage values match dbo.cia_email_instance.resume_processing_stage
(computed off last_completed_stage): B1, B4, B7, B8, or B9. B2/B3 have no
resume entry point of their own — a row that got as far as B.2 or died at
the B.3 check resumes at B4 in the real schema (see recovery/stuck_emails.py).
"""

from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)

_STAGE_ORDER = ["B1", "B2", "B4", "B5", "B6", "B7", "B8", "B9"]


def _b1_write_activity_id(activity_id: str) -> dict[str, Any]:
    logger.debug("[DUMMY B.1] would write activity_id=%s (email # in CRM)", activity_id)
    return {"stage": "B1_write_activity_id", "ok": True}


def _b2_write_queue_item(activity_id: str) -> dict[str, Any]:
    logger.debug("[DUMMY B.2] would write queue-item for activity_id=%s", activity_id)
    return {"stage": "B2_write_queue_item", "ok": True}


def _b3_check_write_success(activity_id: str) -> dict[str, Any]:
    # Real implementation: check B.1/B.2 write result; on failure, update
    # status and EXIT without running B.4 onward. Dummy always succeeds.
    logger.debug("[DUMMY B.3] write success check for activity_id=%s -> success", activity_id)
    return {"stage": "B3_write_check", "ok": True}


def _b4_pull_dataverse_data(activity_id: str) -> dict[str, Any]:
    logger.debug(
        "[DUMMY B.4] would pull email (subject/body/HTML/sender/recipients) and "
        "contact (sender contact_id) data from D365 Dataverse for activity_id=%s",
        activity_id,
    )
    return {"stage": "B4_data_pull_dataverse", "ok": True}


def _b5_process_email(activity_id: str) -> dict[str, Any]:
    logger.debug("[DUMMY B.5] would parse email HTML to text for activity_id=%s", activity_id)
    return {"stage": "B5_parse_email", "ok": True}


def _b6_invoke_agent_workflow(activity_id: str) -> dict[str, Any]:
    logger.debug("[DUMMY B.6] would invoke the agent workflow for activity_id=%s", activity_id)
    return {"stage": "B6_invoke_agent_workflow", "ok": True}


def _b7_decision_actionable_confident(activity_id: str, case_payload: str | None) -> dict[str, Any]:
    # Real implementation: yes -> case payload path; no -> no-case payload
    # path. Dummy always takes the "yes" branch unless a stuck row's saved
    # payload says otherwise.
    actionable = True
    logger.debug(
        "[DUMMY B.7] email actionable and agent confident? for activity_id=%s -> %s",
        activity_id, "yes" if actionable else "no",
    )
    return {"stage": "B7_decision", "ok": True, "actionable": actionable}


def _b8_make_payload(activity_id: str, case_payload: str | None, actionable: bool) -> dict[str, Any]:
    kind = "case payload" if actionable else "no-case payload"
    logger.debug("[DUMMY B.8] would build %s for activity_id=%s", kind, activity_id)
    return {"stage": "B8_make_payload", "ok": True, "payload": case_payload, "kind": kind}


def _b9_post_payload(activity_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    logger.debug(
        "[DUMMY B.9] would POST payload for activity_id=%s (key: activity_id corresponding to email)",
        activity_id,
    )
    return {"stage": "B9_post_payload", "ok": True}


def run_from_stage(
    activity_id: str,
    resume_from_stage: str | None,
    skip_queueitem_write: bool = False,
    case_payload: str | None = None,
) -> dict[str, Any]:
    """Runs the B.1-B.9 spine starting from wherever a recovered attempt left off.

    Args:
        activity_id: the D365 email activity GUID being (re)processed.
        resume_from_stage: one of "B1"/"B4"/"B7"/"B8"/"B9", or None (treated
            as "B1" — a brand-new attempt).
        skip_queueitem_write: True to skip B.2 — a stuck-write retry past
            B.1, where the queue_item already exists.
        case_payload: the previously-saved payload (crm_case_payload), if
            any. Only meaningful when resuming at B8 or B9.

    Returns a dict with the stages actually run and their dummy results —
    shaped like what the real orchestrator will return, so recovery/'s
    caller doesn't need to change when the real implementation lands.
    """
    start_stage = resume_from_stage or "B1"
    if start_stage not in _STAGE_ORDER:
        raise ValueError(f"Unknown resume_from_stage: {start_stage!r}")

    start_index = _STAGE_ORDER.index(start_stage)
    ran: list[dict[str, Any]] = []
    actionable = True

    def _should_run(stage: str) -> bool:
        return _STAGE_ORDER.index(stage) >= start_index

    if _should_run("B1"):
        ran.append(_b1_write_activity_id(activity_id))

    if _should_run("B2") and not skip_queueitem_write:
        ran.append(_b2_write_queue_item(activity_id))
    elif _should_run("B2"):
        logger.debug("[DUMMY B.2] skipped for activity_id=%s (skip_queueitem_write=True)", activity_id)

    if _should_run("B1"):
        # B.3 is a gate right after B.1/B.2, not a resumable stage of its own.
        b3 = _b3_check_write_success(activity_id)
        ran.append(b3)
        if not b3["ok"]:
            return {"activity_id": activity_id, "stopped_at": "B3", "steps": ran}

    if _should_run("B4"):
        ran.append(_b4_pull_dataverse_data(activity_id))

    if _should_run("B5"):
        ran.append(_b5_process_email(activity_id))

    if _should_run("B6"):
        ran.append(_b6_invoke_agent_workflow(activity_id))

    if _should_run("B7"):
        b7 = _b7_decision_actionable_confident(activity_id, case_payload)
        ran.append(b7)
        actionable = b7["actionable"]

    if _should_run("B8"):
        ran.append(_b8_make_payload(activity_id, case_payload, actionable))

    if _should_run("B9"):
        ran.append(_b9_post_payload(activity_id, {"case_payload": case_payload}))

    return {"activity_id": activity_id, "started_at": start_stage, "steps": ran}
