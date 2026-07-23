-- =====================================================================
-- Banking Case Intake AI - Azure SQL DDL
-- Tables: email_instance, queue_item, email_attachment
-- Principle: No raw D365/Dataverse email content (subject, body_html,
-- body_text, sender_email, sender_contact_id) is persisted here.
-- Dataverse remains the sole source of truth for that data.
-- Naming convention: snake_case throughout (tables, columns, constraints)
-- =====================================================================

-- =====================================================================
-- Table: email_instance
-- One row per email/activity being processed by the pipeline.
-- Holds only pipeline-derived state, not raw CRM content.
-- No queue_item_id here by design (relationship lives on queue_item side).
-- =====================================================================
CREATE TABLE dbo.email_instance
(
    activity_id             UNIQUEIDENTIFIER   NOT NULL
        CONSTRAINT pk_email_instance PRIMARY KEY,

    -- Pipeline-derived classification outputs (C.2 / C.3 / C.4)
    classified_subject      NVARCHAR(200)      NULL,   -- HOA taxonomy-based subject (C.2)
    priority                NVARCHAR(50)       NULL,   -- SLA/urgency-derived priority (C.3)
    case_summary            NVARCHAR(MAX)      NULL,   -- Structured summary (C.4)

    -- Agent decision (B.7)
    is_actionable            BIT                NULL,
    agent_confidence_score   DECIMAL(5,4)       NULL,

    -- Case payload built for MuleSoft POST (B.8/B.9)
    case_payload             NVARCHAR(MAX)      NULL,   -- JSON; validated via CHECK constraint

    -- Pipeline status tracking (B.3, D, E)
    status_code              NVARCHAR(50)       NOT NULL
        CONSTRAINT df_email_instance_status_code DEFAULT ('Received'),

    -- status_details: structured JSON diagnostic payload, e.g.
    -- {
    --   "failed_stage": "B6_invoke_agent_workflow",
    --   "error_code": "AgentTimeout",
    --   "error_message": "Foundry agent /agents/priority did not respond within 30s",
    --   "http_status": 504,
    --   "occurred_at": "2026-07-23T10:15:32Z",
    --   "attempt_number": 2
    -- }
    -- Recommended failed_stage values (map to diagram nodes for ops traceability):
    --   'B1_write_activity_id'
    --   'B2_write_queue_item'
    --   'B4_data_pull_dataverse'
    --   'B5_parse_email'
    --   'B6_invoke_agent_workflow'
    --   'B8_make_payload'
    --   'B9_post_case_creation'
    status_details           NVARCHAR(MAX)      NULL,
    retry_count              INT                NOT NULL
        CONSTRAINT df_email_instance_retry_count DEFAULT (0),

    -- Traceability
    -- correlation_id is UNIQUE (not part of the PK) because it is mutable —
    -- Function D may regenerate it per retry attempt. Making a mutable value
    -- part of a primary/composite key would force PK updates on retry and
    -- break any FK/reference pointing at this row (e.g. queue_item joins).
    correlation_id           UNIQUEIDENTIFIER   NULL
        CONSTRAINT uq_email_instance_correlation_id UNIQUE,

    -- Timestamps
    created_date_time        DATETIME2          NOT NULL
        CONSTRAINT df_email_instance_created_date_time DEFAULT (SYSUTCDATETIME()),
    modified_date_time       DATETIME2          NOT NULL
        CONSTRAINT df_email_instance_modified_date_time DEFAULT (SYSUTCDATETIME()),
    case_created_date_time   DATETIME2          NULL,

    -- Feedback loop (Function E: detect banker changes post-case-creation)
    banker_modified_flag     BIT                NOT NULL
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
    )
);
GO

-- Retry lookup used by Function D (recovery for failed cases by status code)
CREATE INDEX ix_email_instance_status_code_retry_count
    ON dbo.email_instance (status_code, retry_count);
GO

-- Note: no separate index needed on correlation_id — the UNIQUE constraint
-- above (uq_email_instance_correlation_id) already creates a unique index.
GO

-- =====================================================================
-- Table: queue_item
-- Lightweight pointer/tracking record per queue item (A.1-A.5 gates).
-- Owns the relationship to email_instance via activity_id.
-- =====================================================================
CREATE TABLE dbo.queue_item
(
    queue_item_id            UNIQUEIDENTIFIER   NOT NULL
        CONSTRAINT pk_queue_item PRIMARY KEY,

    activity_id               UNIQUEIDENTIFIER   NOT NULL,

    -- Gate results (A.2 / A.3 / A.4)
    item_type                 NVARCHAR(50)       NULL,   -- must = 'Email'
    owner_id                  NVARCHAR(100)      NULL,   -- must = 'AAB OPS'
    regarding_id               UNIQUEIDENTIFIER   NULL,   -- must be NULL to proceed
    gate_result                NVARCHAR(20)       NOT NULL
        CONSTRAINT df_queue_item_gate_result DEFAULT ('Pending'),

    -- Queue lifecycle status
    queue_status_code          NVARCHAR(50)       NOT NULL
        CONSTRAINT df_queue_item_queue_status_code DEFAULT ('Enqueued'),

    -- Service Bus pointer message tracking
    service_bus_message_id     NVARCHAR(100)      NULL,

    received_date_time          DATETIME2          NULL,   -- CRM release timestamp
    enqueued_date_time           DATETIME2          NULL,   -- Service Bus enqueue timestamp
    processed_date_time          DATETIME2          NULL,   -- Orchestrator pickup timestamp

    correlation_id                 UNIQUEIDENTIFIER   NULL,

    CONSTRAINT ck_queue_item_gate_result CHECK (gate_result IN ('Pending', 'Pass', 'Stop')),
    CONSTRAINT ck_queue_item_queue_status_code CHECK (queue_status_code IN (
        'Enqueued', 'Released', 'WorkedByServiceAccount'
    )),
    CONSTRAINT fk_queue_item_email_instance FOREIGN KEY (activity_id)
        REFERENCES dbo.email_instance (activity_id)
);
GO

CREATE INDEX ix_queue_item_activity_id
    ON dbo.queue_item (activity_id);
GO

CREATE INDEX ix_queue_item_correlation_id
    ON dbo.queue_item (correlation_id);
GO

-- =====================================================================
-- Table: email_attachment
-- Metadata pointer only — attachment binary/base64 content stays in
-- Dataverse and is NOT persisted here, consistent with the principle
-- that raw CRM/email content lives only in Dataverse.
-- =====================================================================
CREATE TABLE dbo.email_attachment
(
    attachment_id              UNIQUEIDENTIFIER   NOT NULL
        CONSTRAINT pk_email_attachment PRIMARY KEY,

    activity_id                 UNIQUEIDENTIFIER   NOT NULL,

    file_name                    NVARCHAR(260)      NULL,
    content_type                 NVARCHAR(100)      NULL,
    -- Reference only, e.g. Dataverse annotation/document ID - not the content itself
    dataverse_attachment_ref     NVARCHAR(200)      NULL,

    CONSTRAINT fk_email_attachment_email_instance FOREIGN KEY (activity_id)
        REFERENCES dbo.email_instance (activity_id)
);
GO

CREATE INDEX ix_email_attachment_activity_id
    ON dbo.email_attachment (activity_id);
GO
