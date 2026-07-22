-- ============================================================
-- Email Instance Table
-- Purpose : Tracks every email through the case intake pipeline
-- PK      : ActivityId (D365 email activity GUID)
-- Env     : Create per environment (dev / UAT / prod)
-- ============================================================

CREATE TABLE dbo.EmailInstanceTracking
(
    -- ── Identity ─────────────────────────────────────────────
    ActivityId          NVARCHAR(50)    NOT NULL,
    CorrelationId       NVARCHAR(50)    NOT NULL,

    -- ── Status tracking ──────────────────────────────────────
    Status              NVARCHAR(20)    NOT NULL
        CONSTRAINT CHK_EIT_Status
            CHECK (Status IN ('InProgress', 'Completed', 'Failed')),

    StatusCode          NVARCHAR(100)   NULL,

    -- ── AI classification results ────────────────────────────
    AgentSubjectId      NVARCHAR(50)    NULL,
    AgentSubjectName    NVARCHAR(255)   NULL,
    AgentPriorityCode   INT             NULL
        CONSTRAINT CHK_EIT_Priority
            CHECK (AgentPriorityCode IN (1, 2, 3) OR AgentPriorityCode IS NULL),
    AgentConfidenceScore DECIMAL(5,4)   NULL,   -- e.g. 0.8400

    -- ── Case outcome ─────────────────────────────────────────
    CaseId              NVARCHAR(50)    NULL,
    CaseCreatedOn       DATETIME2       NULL,

    -- ── Retry tracking ───────────────────────────────────────
    RetryCount          INT             NOT NULL    DEFAULT 0,
    LastRetryAt         DATETIME2       NULL,

    -- ── Audit timestamps ─────────────────────────────────────
    CreatedAt           DATETIME2       NOT NULL    DEFAULT GETUTCDATE(),
    UpdatedAt           DATETIME2       NOT NULL    DEFAULT GETUTCDATE(),

    -- ── Constraints ──────────────────────────────────────────
    CONSTRAINT PK_EmailInstanceTracking
        PRIMARY KEY CLUSTERED (ActivityId ASC)
);
GO

-- ── Indexes ──────────────────────────────────────────────────

-- Status index — used by recovery function (Function D)
-- to scan for Failed rows efficiently
CREATE NONCLUSTERED INDEX IX_EIT_Status
    ON dbo.EmailInstanceTracking (Status)
    INCLUDE (ActivityId, StatusCode, RetryCount, UpdatedAt);
GO

-- CorrelationId index — used by App Insights queries
-- and observability lookups
CREATE NONCLUSTERED INDEX IX_EIT_CorrelationId
    ON dbo.EmailInstanceTracking (CorrelationId)
    INCLUDE (Status, CaseId, CreatedAt);
GO

-- CreatedAt index — used by date-range audit queries
CREATE NONCLUSTERED INDEX IX_EIT_CreatedAt
    ON dbo.EmailInstanceTracking (CreatedAt DESC)
    INCLUDE (Status, CaseId, CorrelationId);
GO

-- ── Comments ─────────────────────────────────────────────────

EXEC sp_addextendedproperty
    @name       = N'MS_Description',
    @value      = N'Tracks every email through the case intake pipeline from detection to case creation or failure',
    @level0type = N'SCHEMA', @level0name = N'dbo',
    @level1type = N'TABLE',  @level1name = N'EmailInstanceTracking';
GO

EXEC sp_addextendedproperty
    @name       = N'MS_Description',
    @value      = N'D365 email activity GUID — primary key and natural identifier for the email throughout the pipeline',
    @level0type = N'SCHEMA', @level0name = N'dbo',
    @level1type = N'TABLE',  @level1name = N'EmailInstanceTracking',
    @level2type = N'COLUMN', @level2name = N'ActivityId';
GO

EXEC sp_addextendedproperty
    @name       = N'MS_Description',
    @value      = N'Equals ActivityId — carried explicitly so downstream consumers do not need to know the correlation key is the activity ID',
    @level0type = N'SCHEMA', @level0name = N'dbo',
    @level1type = N'TABLE',  @level1name = N'EmailInstanceTracking',
    @level2type = N'COLUMN', @level2name = N'CorrelationId';
GO

EXEC sp_addextendedproperty
    @name       = N'MS_Description',
    @value      = N'Pipeline status: InProgress on orchestration start, Completed on case creation, Failed after max retries',
    @level0type = N'SCHEMA', @level0name = N'dbo',
    @level1type = N'TABLE',  @level1name = N'EmailInstanceTracking',
    @level2type = N'COLUMN', @level2name = N'Status';
GO

EXEC sp_addextendedproperty
    @name       = N'MS_Description',
    @value      = N'Detail code on failure — e.g. LOW_CONFIDENCE, PARSE_ERROR, AGENT_TIMEOUT, CASE_CREATE_FAILED',
    @level0type = N'SCHEMA', @level0name = N'dbo',
    @level1type = N'TABLE',  @level1name = N'EmailInstanceTracking',
    @level2type = N'COLUMN', @level2name = N'StatusCode';
GO