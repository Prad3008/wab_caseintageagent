-- =====================================================================
-- Banking Case Intake AI - Azure SQL DDL
-- Tables: EmailInstance, QueueItem, EmailAttachment
-- Principle: No raw D365/Dataverse email content (Subject, BodyHtml,
-- BodyText, SenderEmail, SenderContactId) is persisted here.
-- Dataverse remains the sole source of truth for that data.
-- =====================================================================

-- =====================================================================
-- Table: EmailInstance
-- One row per email/activity being processed by the pipeline.
-- Holds only pipeline-derived state, not raw CRM content.
-- No QueueItemId here by design (relationship lives on QueueItem side).
-- =====================================================================
CREATE TABLE dbo.EmailInstance
(
    ActivityId              UNIQUEIDENTIFIER   NOT NULL
        CONSTRAINT PK_EmailInstance PRIMARY KEY,

    -- Pipeline-derived classification outputs (C.2 / C.3 / C.4)
    ClassifiedSubject       NVARCHAR(200)      NULL,   -- HOA taxonomy-based subject (C.2)
    Priority                NVARCHAR(50)       NULL,   -- SLA/urgency-derived priority (C.3)
    CaseSummary             NVARCHAR(MAX)      NULL,   -- Structured summary (C.4)

    -- Agent decision (B.7)
    IsActionable            BIT                NULL,
    AgentConfidenceScore    DECIMAL(5,4)       NULL,

    -- Case payload built for MuleSoft POST (B.8/B.9)
    CasePayload             NVARCHAR(MAX)      NULL,   -- JSON; validate with ISJSON in CHECK constraint

    -- Pipeline status tracking (B.3, D, E)
    StatusCode              NVARCHAR(50)       NOT NULL
        CONSTRAINT DF_EmailInstance_StatusCode DEFAULT ('Received'),
    StatusDetails           NVARCHAR(MAX)      NULL,
    RetryCount              INT                NOT NULL
        CONSTRAINT DF_EmailInstance_RetryCount DEFAULT (0),

    -- Traceability
    CorrelationId           UNIQUEIDENTIFIER   NULL,

    -- Timestamps
    CreatedDateTime         DATETIME2          NOT NULL
        CONSTRAINT DF_EmailInstance_CreatedDateTime DEFAULT (SYSUTCDATETIME()),
    ModifiedDateTime        DATETIME2          NOT NULL
        CONSTRAINT DF_EmailInstance_ModifiedDateTime DEFAULT (SYSUTCDATETIME()),
    CaseCreatedDateTime     DATETIME2          NULL,

    -- Feedback loop (Function E: detect banker changes post-case-creation)
    BankerModifiedFlag      BIT                NOT NULL
        CONSTRAINT DF_EmailInstance_BankerModifiedFlag DEFAULT (0),

    CONSTRAINT CK_EmailInstance_StatusCode CHECK (StatusCode IN (
        'Received', 'DataPulled', 'Processed', 'AgentInvoked',
        'PayloadCreated', 'PayloadPosted', 'CaseCreated',
        'NoCasePayload', 'Failed', 'ExitedNoRetry'
    )),
    CONSTRAINT CK_EmailInstance_CasePayload_IsJson CHECK (
        CasePayload IS NULL OR ISJSON(CasePayload) = 1
    )
);
GO

-- Retry lookup used by Function D (recovery for failed cases by status code)
CREATE INDEX IX_EmailInstance_StatusCode_RetryCount
    ON dbo.EmailInstance (StatusCode, RetryCount);
GO

-- Correlation lookup for tracing across App Insights / Log Analytics
CREATE INDEX IX_EmailInstance_CorrelationId
    ON dbo.EmailInstance (CorrelationId);
GO

-- =====================================================================
-- Table: QueueItem
-- Lightweight pointer/tracking record per queue item (A.1-A.5 gates).
-- Owns the relationship to EmailInstance via ActivityId.
-- =====================================================================
CREATE TABLE dbo.QueueItem
(
    QueueItemId             UNIQUEIDENTIFIER   NOT NULL
        CONSTRAINT PK_QueueItem PRIMARY KEY,

    ActivityId              UNIQUEIDENTIFIER   NOT NULL,

    -- Gate results (A.2 / A.3 / A.4)
    ItemType                NVARCHAR(50)       NULL,   -- must = 'Email'
    OwnerId                 NVARCHAR(100)      NULL,   -- must = 'AAB OPS'
    RegardingId             UNIQUEIDENTIFIER   NULL,   -- must be NULL to proceed
    GateResult              NVARCHAR(20)       NOT NULL
        CONSTRAINT DF_QueueItem_GateResult DEFAULT ('Pending'),

    -- Queue lifecycle status
    QueueStatusCode         NVARCHAR(50)       NOT NULL
        CONSTRAINT DF_QueueItem_QueueStatusCode DEFAULT ('Enqueued'),

    -- Service Bus pointer message tracking
    ServiceBusMessageId     NVARCHAR(100)      NULL,

    ReceivedDateTime        DATETIME2          NULL,   -- CRM release timestamp
    EnqueuedDateTime        DATETIME2          NULL,   -- Service Bus enqueue timestamp
    ProcessedDateTime       DATETIME2          NULL,   -- Orchestrator pickup timestamp

    RetryCount              INT                NOT NULL
        CONSTRAINT DF_QueueItem_RetryCount DEFAULT (0),

    CorrelationId           UNIQUEIDENTIFIER   NULL,

    CONSTRAINT CK_QueueItem_GateResult CHECK (GateResult IN ('Pending', 'Pass', 'Stop')),
    CONSTRAINT CK_QueueItem_QueueStatusCode CHECK (QueueStatusCode IN (
        'Enqueued', 'Released', 'WorkedByServiceAccount'
    )),
    CONSTRAINT FK_QueueItem_EmailInstance FOREIGN KEY (ActivityId)
        REFERENCES dbo.EmailInstance (ActivityId)
);
GO

CREATE INDEX IX_QueueItem_ActivityId
    ON dbo.QueueItem (ActivityId);
GO

CREATE INDEX IX_QueueItem_CorrelationId
    ON dbo.QueueItem (CorrelationId);
GO

-- =====================================================================
-- Table: EmailAttachment
-- Metadata pointer only — attachment binary/base64 content stays in
-- Dataverse and is NOT persisted here, consistent with the principle
-- that raw CRM/email content lives only in Dataverse.
-- =====================================================================
CREATE TABLE dbo.EmailAttachment
(
    AttachmentId            UNIQUEIDENTIFIER   NOT NULL
        CONSTRAINT PK_EmailAttachment PRIMARY KEY,

    ActivityId               UNIQUEIDENTIFIER   NOT NULL,

    FileName                 NVARCHAR(260)      NULL,
    ContentType              NVARCHAR(100)      NULL,
    -- Reference only, e.g. Dataverse annotation/document ID - not the content itself
    DataverseAttachmentRef   NVARCHAR(200)      NULL,

    CONSTRAINT FK_EmailAttachment_EmailInstance FOREIGN KEY (ActivityId)
        REFERENCES dbo.EmailInstance (ActivityId)
);
GO

CREATE INDEX IX_EmailAttachment_ActivityId
    ON dbo.EmailAttachment (ActivityId);
GO
