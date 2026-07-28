-- Banking Case Intake AI - Azure SQL DDL
-- Table: email_instance
-- Principle: No raw D365/Dataverse email body content (body_html,
-- body_text, sender_email, sender_contact_id) is persisted here.
-- Naming convention: snake_case throughout.
--
-- RETRY MODEL (append-only attempt log):
--   email_instance = one row PER ATTEMPT (PK = correlation_id).
--   A retry INSERTS a new row with a new correlation_id and incremented
--   attempt_number against the same activity_id; it never updates an
--   older row's correlation_id.
--
-- RECOVERY MODEL:
--   1. No row exists at all for activity_id -> true orphan. Cannot be
--      detected from this table. Recovery reconciles against Service
--      Bus (dead-letter / stuck messages) and starts a brand new
--      attempt at B.1 -> B.2 -> B.4 (nothing to skip).
--   2. A row exists -> every resume still performs B.1 (new
--      correlation_id, new email_instance row, activity_id write)
--      unconditionally. B.2 (queue_item write) is conditionally
--      SKIPPED if it already succeeded on the prior attempt -- see
--      skip_b2 below -- since queue_item is keyed by activity_id and
--      rewriting it would be redundant, not idempotent-safe.
--   3. Processing resumes at the stage immediately after the highest
--      stage the PRIOR attempt completed -- see resume_processing_stage
--      below. If the prior row's last_completed_stage is NULL, even
--      B.1 never confirmed completion (crash before checkpoint), so
--      the new attempt resumes at B1 and B.2 is NOT skipped. B.4-B.6
--      always collapse to a B.4 restart regardless of exactly which
--      of the three failed, because raw email content is never
--      persisted outside CRM, so there is nothing to resume mid-way
--      through that block. B.7, B.8, and B.9 each get their own
--      precise resume point because their prerequisite outputs
--      (classification, decision, payload) ARE persisted here.
--
-- last_completed_stage IS UPDATED PROGRESSIVELY ON THE CURRENT ATTEMPT
-- ROW as each activity succeeds -- it is not only set at the end.
-- This is what makes it possible to know, after a failure, exactly
-- how far this attempt got.
--
-- INSERT-TIME COPY-FORWARD RULE for a new attempt row (uses
-- previous_correlation_id to identify the source row):
--   resume_processing_stage = 'B4' -> classification columns NULL;
--     nothing to reuse, B.4 re-pulls the email fresh from Dataverse.
--   resume_processing_stage = 'B7' -> classified_subject, priority,
--     case_summary, agent_confidence_score copied forward from
--     previous_correlation_id's row. is_actionable and case_payload
--     stay NULL (not yet decided).
--   resume_processing_stage = 'B8' -> everything above, PLUS
--     is_actionable copied forward. case_payload stays NULL.
--   resume_processing_stage = 'B9' -> everything above, PLUS
--     case_payload copied forward (already built, just needs posting).
--
-- NOTE: activity_id is NOT unique in email_instance (it repeats across
-- attempts), so queue_item / email_attachment reference it as a plain
-- indexed column rather than an enforced FK. Referential integrity for
-- that link, and for previous_correlation_id, is maintained at the
-- application layer.
-- =====================================================================

-- =====================================================================
-- Table: email_instance
-- One row PER ATTEMPT. PK = correlation_id (fresh value minted per
-- retry). activity_id repeats across attempts for the same email.
-- =====================================================================
CREATE TABLE dbo.email_instance
(
    correlation_id            UNIQUEIDENTIFIER   NOT NULL
        CONSTRAINT pk_email_instance PRIMARY KEY,

    activity_id               UNIQUEIDENTIFIER   NOT NULL,

    -- attempt_number IS the retry count for this activity_id -- no
    -- separate retry_count column needed. First attempt = 1, etc.
    attempt_number             INT                NOT NULL
        CONSTRAINT df_email_instance_attempt_number DEFAULT (1),

    -- Lineage for retries: correlation_id of the attempt this row's
    -- carried-forward data was copied from. NULL on a first attempt,
    -- or when resume_processing_stage = 'B4' (nothing carried forward).
    previous_correlation_id   UNIQUEIDENTIFIER   NULL,

    -- NOTE: raw subject re-introduced (against the general "no raw CRM
    -- data" principle) because Function D filters failed items by
    -- "Subject and unique email id" per the diagram. Fetched fresh from
    -- Dataverse on each attempt at B.4, so storing it per-attempt is
    -- consistent with the rest of this table's per-attempt data.
    subject                   NVARCHAR(500)      NULL,

    -- Pipeline-derived classification outputs (C.2 / C.3 / C.4)
    classified_subject        NVARCHAR(200)      NULL,
    priority                  NVARCHAR(50)       NULL,
    case_summary              NVARCHAR(MAX)      NULL,

    -- Agent decision (B.7)
    is_actionable             BIT                NULL,
    agent_confidence_score    DECIMAL(5,4)       NULL,

    -- Case payload built for MuleSoft POST (B.8/B.9)
    case_payload              NVARCHAR(MAX)      NULL,   -- JSON; validated via CHECK

    -- D365 case ID, populated after B.9 POST succeeds on THIS attempt.
    -- Function D should check the latest attempt's case_id (see view
    -- below) before retrying, to avoid duplicate case creation.
    case_id                   UNIQUEIDENTIFIER   NULL,

    -- Pipeline status tracking for THIS attempt (B.3, D, E)
    status_code               NVARCHAR(50)       NOT NULL
        CONSTRAINT df_email_instance_status_code DEFAULT ('Received'),

    -- Highest stage this attempt has SUCCESSFULLY completed so far.
    -- Updated progressively as the orchestration advances -- not only
    -- at the point of failure. Drives both resume_processing_stage and
    -- skip_b2 below. NULL means this attempt has not completed any
    -- stage yet (B.1 itself is in flight or about to start).
    last_completed_stage      NVARCHAR(50)       NULL
        CONSTRAINT ck_email_instance_last_completed_stage CHECK (
            last_completed_stage IS NULL OR last_completed_stage IN (
                'B1_write_activity_id', 'B2_write_queue_item',
                'B4_data_pull_dataverse', 'B5_parse_email',
                'B6_invoke_agent_workflow', 'B7_decision',
                'B8_make_payload', 'B9_post_case_creation'
            )
        ),

    -- status_details: structured JSON diagnostic payload, e.g.
    -- {
    --   "failed_stage": "B6_invoke_agent_workflow",
    --   "error_code": "AgentTimeout",
    --   "error_message": "Foundry agent /agents/priority did not respond within 30s",
    --   "http_status": 504,
    --   "occurred_at": "2026-07-23T10:15:32Z"
    -- }
    -- Diagnostic only -- resume branching runs off last_completed_stage,
    -- not off this field, since last_completed_stage is a positive
    -- record of success rather than an inferred error label.
    status_details            NVARCHAR(MAX)      NULL,

    created_date_time         DATETIME2          NOT NULL
        CONSTRAINT df_email_instance_created_date_time DEFAULT (SYSUTCDATETIME()),
    modified_date_time        DATETIME2          NOT NULL
        CONSTRAINT df_email_instance_modified_date_time DEFAULT (SYSUTCDATETIME()),
    case_created_date_time    DATETIME2          NULL,

    banker_modified_flag      BIT                NOT NULL
        CONSTRAINT df_email_instance_banker_modified_flag DEFAULT (0),

    -- Diagnostic only: failed_stage pulled out of status_details JSON.
    failed_stage AS (
        JSON_VALUE(status_details, '$.failed_stage')
    ) PERSISTED,

    -- Where a NEW attempt's processing should resume, based on the
    -- PRIOR attempt's last_completed_stage.
    -- NULL means the prior attempt's row exists but B.1 itself never
    -- confirmed completion (crash between insert and checkpoint, or
    -- B.1 failed partway) -- this is NOT the same as B.1 having
    -- succeeded, so it must resume at B1, redoing B.1 and B.2 both.
    -- B1/B2 (once B.1 IS confirmed) collapse to B4 -- nothing durable
    -- exists yet to resume mid-way through data pull / parse / agent
    -- invocation.
    resume_processing_stage AS (
        CASE last_completed_stage
            WHEN 'B1_write_activity_id'     THEN 'B4'
            WHEN 'B2_write_queue_item'      THEN 'B4'
            WHEN 'B4_data_pull_dataverse'   THEN 'B4'
            WHEN 'B5_parse_email'           THEN 'B4'
            WHEN 'B6_invoke_agent_workflow' THEN 'B7'
            WHEN 'B7_decision'              THEN 'B8'
            WHEN 'B8_make_payload'          THEN 'B9'
            ELSE 'B1'
        END
    ) PERSISTED,

    -- Whether the new attempt can SKIP B.2 (queue_item write) because
    -- it already succeeded on the prior attempt. Only false when the
    -- prior attempt never got past B.1.
    skip_b2 AS (
        CASE
            WHEN last_completed_stage IS NOT NULL
                 AND last_completed_stage <> 'B1_write_activity_id'
                THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END
    ) PERSISTED,

    CONSTRAINT ck_email_instance_status_code CHECK (status_code IN (
        'Received', 'DataPulled', 'Processed', 'AgentInvoked',
        'PayloadCreated', 'PayloadPosted', 'CaseCreated',
        'NoCasePayload', 'Failed', 'ExitedNoRetry'
    )),
    CONSTRAINT ck_email_instance_case_payload_is_json CHECK (
        case_payload IS NULL OR ISJSON(case_payload) = 1
    ),
    CONSTRAINT ck_email_instance_status_details_is_json CHECK (
        status_details IS NULL OR ISJSON(status_details) = 1
    ),
    -- Guarantees no two rows claim to be the same attempt number for the
    -- same email (defensive, catches app-level bugs / race conditions).
    CONSTRAINT uq_email_instance_activity_attempt UNIQUE (activity_id, attempt_number)
);
GO

-- Find all attempts for an activity, ordered by recency
CREATE INDEX ix_email_instance_activity_id_created
    ON dbo.email_instance (activity_id, created_date_time DESC);
GO

-- Function D: scan failed attempts by status code
CREATE INDEX ix_email_instance_status_code
    ON dbo.email_instance (status_code);
GO

-- Function D: "Filter with Subject and unique email id"
CREATE INDEX ix_email_instance_subject_activity_id
    ON dbo.email_instance (subject, activity_id);
GO

-- Diagnostics: scan failed attempts by which pipeline stage failed
CREATE INDEX ix_email_instance_failed_stage
    ON dbo.email_instance (failed_stage)
    WHERE status_code = 'Failed';
GO

-- Function D: branch a retry to the correct resume point
CREATE INDEX ix_email_instance_resume_processing_stage
    ON dbo.email_instance (resume_processing_stage)
    WHERE status_code = 'Failed';
GO

-- Trace which prior attempt a retry's carried-forward data came from
CREATE INDEX ix_email_instance_previous_correlation_id
    ON dbo.email_instance (previous_correlation_id);
GO
