-- =====================================================================
-- Stored Procedure : dbo.usp_cia_email_instance_b1_write
-- Purpose           : B.1 write - insert a new attempt row into
--                     dbo.cia_email_instance for a given activity_id.
--                     Handles both first-attempt and retry paths, and
--                     carries forward only the fields valid to reuse
--                     based on the prior attempt's resume_processing_stage.
--
-- Inputs  : @activity_id  - D365 email activity GUID (same across all
--                           attempts for one email)
--           @subject      - freshly pulled subject for THIS attempt
--                           (always re-pulled from CRM, never carried
--                           forward)
--
-- Outputs : @new_email_instance_id  - PK of the row just inserted
--           @skip_queueitem_write   - computed flag from the new row,
--                                     returned so the caller (B.2) can
--                                     decide whether to write a fresh
--                                     queue_item or reuse the existing one
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_cia_email_instance_b1_write
    @activity_id            UNIQUEIDENTIFIER,
    @subject                NVARCHAR(500) = NULL,
    @new_email_instance_id  UNIQUEIDENTIFIER OUTPUT,
    @skip_queueitem_write   BIT              OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRANSACTION;

    BEGIN TRY

        -- -----------------------------------------------------------------
        -- Check whether any attempt already exists for this activity_id.
        -- WITH (UPDLOCK, HOLDLOCK) here (and on the subquery below) is what
        -- makes this safe under concurrent retries: it takes and holds a
        -- lock on the matching rows for the duration of the transaction, so
        -- two Recovery Function instances racing on the same activity_id
        -- can't both read the same "latest" attempt_number and insert
        -- duplicates -- which would otherwise violate
        -- uq_email_instance_activity_attempt as a runtime error rather than
        -- being handled gracefully.
        -- -----------------------------------------------------------------
        IF EXISTS (
            SELECT 1
            FROM dbo.cia_email_instance WITH (UPDLOCK, HOLDLOCK)
            WHERE activity_id = @activity_id
        )
        BEGIN
            -- ---------------------------------------------------------------
            -- RETRY PATH
            -- A prior attempt exists. Derive, from that latest prior row:
            --   - the next attempt_number (prior + 1)
            -- ---------------------------------------------------------------
            DECLARE @output_ids TABLE (email_instance_id UNIQUEIDENTIFIER);

            INSERT INTO dbo.cia_email_instance
            (
                activity_id,
                attempt_number,
                previous_email_instance_id,
                banker_subject,
                agent_subject,
                agent_case_priority,
                agent_case_description,
                agent_response,
                agent_action_flag,
                agent_confidence_score,
                crm_case_payload,
                status_code,
                last_completed_stage
            )
            OUTPUT inserted.email_instance_id INTO @output_ids
            SELECT
                @activity_id,
                prior.attempt_number + 1,                -- next attempt number
                prior.email_instance_id,                 -- lineage: points back to the row we resumed from

                @subject,

                -- Classification fields: carried forward once B.6 has
                -- previously succeeded (i.e. prior resumed at B7 or later)
                CASE WHEN prior.resume_processing_stage IN ('B7','B8','B9')
                     THEN prior.agent_subject ELSE NULL END,
                CASE WHEN prior.resume_processing_stage IN ('B7','B8','B9')
                     THEN prior.agent_case_priority ELSE NULL END,
                CASE WHEN prior.resume_processing_stage IN ('B7','B8','B9')
                     THEN prior.agent_case_description ELSE NULL END,
                CASE WHEN prior.resume_processing_stage IN ('B7','B8','B9')
                     THEN prior.agent_response ELSE NULL END,

                -- Decision field: only valid once B.7 has previously
                -- succeeded (i.e. prior resumed at B8 or later)
                CASE WHEN prior.resume_processing_stage IN ('B8','B9')
                     THEN prior.agent_action_flag ELSE NULL END,

                CASE WHEN prior.resume_processing_stage IN ('B7','B8','B9')
                     THEN prior.agent_confidence_score ELSE NULL END,

                -- Payload: only valid once B.8 has previously succeeded
                -- (i.e. prior resumed at B9 -- just needs re-posting)
                CASE WHEN prior.resume_processing_stage = 'B9'
                     THEN prior.crm_case_payload ELSE NULL END,

                1,                                          -- status_code = 1 ('Email received from queue')
                prior.last_completed_stage
            FROM (
                -- Latest prior attempt for this activity_id, locked to
                -- prevent a concurrent retry from reading the same row.
                SELECT TOP 1 *
                FROM dbo.cia_email_instance WITH (UPDLOCK, HOLDLOCK)
                WHERE activity_id = @activity_id
                ORDER BY attempt_number DESC
            ) AS prior;

            SELECT @new_email_instance_id = email_instance_id FROM @output_ids;
        END
        ELSE
        BEGIN
            -- ---------------------------------------------------------------
            -- FIRST ATTEMPT PATH
            -- No prior row exists for this activity_id at all -- nothing to
            -- carry forward, nothing to derive. attempt_number starts at 1,
            -- previous_email_instance_id stays NULL (no lineage yet).
            -- ---------------------------------------------------------------
            DECLARE @output_ids_first TABLE (email_instance_id UNIQUEIDENTIFIER);

            INSERT INTO dbo.cia_email_instance
            (
                activity_id,
                attempt_number,
                banker_subject,
                status_code,
                last_completed_stage
            )
            OUTPUT inserted.email_instance_id INTO @output_ids_first
            VALUES
            (
                @activity_id,
                1,                          -- first attempt
                @subject,
                1,                          -- status_code = 1 ('Email received from queue')
                'B1_write_activity_id'
            );

            SELECT @new_email_instance_id = email_instance_id FROM @output_ids_first;
        END

        -- ---------------------------------------------------------------
        -- Return the computed skip_queueitem_write flag from the row
        -- just inserted, so the caller (B.2) knows whether to write a
        -- fresh queue_item or reuse the existing one.
        -- ---------------------------------------------------------------
        SELECT @skip_queueitem_write = skip_queueitem_write
        FROM dbo.cia_email_instance
        WHERE email_instance_id = @new_email_instance_id;

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END
GO


DECLARE @new_id       UNIQUEIDENTIFIER;
DECLARE @skip_queue   BIT;

EXEC dbo.usp_cia_email_instance_b1_write
    @activity_id           = '11111111-1111-1111-1111-111111111111',
    @subject               = NULL,
    @new_email_instance_id = @new_id OUTPUT,
    @skip_queueitem_write  = @skip_queue OUTPUT;

SELECT @new_id AS new_email_instance_id, @skip_queue AS skip_queueitem_write;