-- =====================================================================
-- Banking Case Intake AI - Azure SQL DDL
-- Tables: email_instance, queue_item, email_attachment
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
-- NOTE: activity_id is NOT unique in email_instance (it repeats across
-- attempts), so queue_item / email_attachment reference it as a plain
-- indexed column rather than an enforced FK. Referential integrity for
-- that link is maintained at the application layer.
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

    -- attempt_number IS the retry count for this activity_id — no separate
    -- retry_count column needed. First attempt = 1, first retry = 2, etc.
    attempt_number            INT                NOT NULL
        CONSTRAINT df_email_instance_attempt_number DEFAULT (1),

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

    -- status_details: structured JSON diagnostic payload, e.g.
    -- {
    --   "failed_stage": "B6_invoke_agent_workflow",
    --   "error_code": "AgentTimeout",
    --   "error_message": "Foundry agent /agents/priority did not respond within 30s",
    --   "http_status": 504,
    --   "occurred_at": "2026-07-23T10:15:32Z"
    -- }
    -- Recommended failed_stage values (map to diagram nodes):
    --   'B1_write_activity_id' | 'B2_write_queue_item' | 'B4_data_pull_dataverse'
    --   'B5_parse_email' | 'B6_invoke_agent_workflow' | 'B8_make_payload'
    --   'B9_post_case_creation'
    status_details            NVARCHAR(MAX)      NULL,

    created_date_time         DATETIME2          NOT NULL
        CONSTRAINT df_email_instance_created_date_time DEFAULT (SYSUTCDATETIME()),
    modified_date_time        DATETIME2          NOT NULL
        CONSTRAINT df_email_instance_modified_date_time DEFAULT (SYSUTCDATETIME()),
    case_created_date_time    DATETIME2          NULL,

    banker_modified_flag      BIT                NOT NULL
        CONSTRAINT df_email_instance_banker_modified_flag DEFAULT (0),

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

-- =====================================================================
-- View: vw_email_instance_latest
-- Convenience view returning only the most recent attempt per activity.
-- Function D and dashboards should query this instead of hand-rolling
-- a window/MAX function every time.
-- =====================================================================
CREATE VIEW dbo.vw_email_instance_latest
AS
SELECT ei.*
FROM dbo.email_instance ei
INNER JOIN (
    SELECT activity_id, MAX(attempt_number) AS max_attempt_number
    FROM dbo.email_instance
    GROUP BY activity_id
) latest
    ON latest.activity_id = ei.activity_id
    AND latest.max_attempt_number = ei.attempt_number;
GO

-- =====================================================================
-- Table: queue_item
-- Lightweight pointer/tracking record per queue item (A.1-A.5 gates).
-- activity_id is a plain indexed column here (NOT an enforced FK),
-- since email_instance.activity_id is no longer unique across attempts.
-- =====================================================================
CREATE TABLE dbo.queue_item
(
    queue_item_id             UNIQUEIDENTIFIER   NOT NULL
        CONSTRAINT pk_queue_item PRIMARY KEY,

    activity_id                UNIQUEIDENTIFIER   NOT NULL,

    item_type                  NVARCHAR(50)       NULL,
    owner_id                   NVARCHAR(100)      NULL,
    regarding_id                UNIQUEIDENTIFIER   NULL,
    gate_result                 NVARCHAR(20)       NOT NULL
        CONSTRAINT df_queue_item_gate_result DEFAULT ('Pending'),

    queue_status_code           NVARCHAR(50)       NOT NULL
        CONSTRAINT df_queue_item_queue_status_code DEFAULT ('Enqueued'),

    service_bus_message_id      NVARCHAR(100)      NULL,

    received_date_time           DATETIME2          NULL,
    enqueued_date_time            DATETIME2          NULL,
    processed_date_time           DATETIME2          NULL,

    CONSTRAINT ck_queue_item_gate_result CHECK (gate_result IN ('Pending', 'Pass', 'Stop')),
    CONSTRAINT ck_queue_item_queue_status_code CHECK (queue_status_code IN (
        'Enqueued', 'Released', 'WorkedByServiceAccount'
    ))
);
GO

CREATE INDEX ix_queue_item_activity_id
    ON dbo.queue_item (activity_id);
GO

-- =====================================================================
-- Table: email_attachment
-- Metadata pointer only. activity_id is a plain indexed column (not an
-- enforced FK), same reasoning as queue_item above.
-- =====================================================================
CREATE TABLE dbo.email_attachment
(
    attachment_id               UNIQUEIDENTIFIER   NOT NULL
        CONSTRAINT pk_email_attachment PRIMARY KEY,

    activity_id                  UNIQUEIDENTIFIER   NOT NULL,

    file_name                     NVARCHAR(260)      NULL,
    content_type                  NVARCHAR(100)      NULL,
    dataverse_attachment_ref      NVARCHAR(200)      NULL
);
GO

CREATE INDEX ix_email_attachment_activity_id
    ON dbo.email_attachment (activity_id);
GO
