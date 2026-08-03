/****** Object:  Table [dbo].[cia_email_instance]    Script Date: 8/3/2026 5:10:12 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[cia_email_instance](
	[email_instance_id] [uniqueidentifier] NOT NULL,
	[activity_id] [uniqueidentifier] NOT NULL,
	[attempt_number] [int] NOT NULL,
	[previous_email_instance_id] [uniqueidentifier] NULL,
	[banker_subject] [nvarchar](500) NULL,
	[agent_subject] [nvarchar](200) NULL,
	[agent_case_priority] [nvarchar](50) NULL,
	[agent_case_description] [nvarchar](max) NULL,
	[agent_response] [nvarchar](max) NULL,
	[agent_action_flag] [bit] NULL,
	[agent_confidence_score] [decimal](5, 4) NULL,
	[crm_case_payload] [nvarchar](max) NULL,
	[crm_case_id] [uniqueidentifier] NULL,
	[status_code] [int] NULL,
	[last_completed_stage] [nvarchar](50) NULL,
	[status_details] [nvarchar](max) NULL,
	[created_date_time] [datetime2](7) NOT NULL,
	[modified_date_time] [datetime2](7) NOT NULL,
	[case_created_date_time] [datetime2](7) NULL,
	[banker_modified_flag] [bit] NOT NULL,
	[failed_stage]  AS (json_value([status_details],'$.failed_stage')) PERSISTED,
	[resume_processing_stage]  AS (case [last_completed_stage] when 'B1_write_activity_id' then 'B4' when 'B2_write_queue_item' then 'B4' when 'B4_data_pull_dataverse' then 'B4' when 'B5_parse_email' then 'B4' when 'B6_invoke_agent_workflow' then 'B7' when 'B7_decision' then 'B8' when 'B8_make_payload' then 'B9' else 'B1' end) PERSISTED NOT NULL,
	[skip_queueitem_write]  AS (case when [last_completed_stage] IS NOT NULL AND [last_completed_stage]<>'B1_write_activity_id' then CONVERT([bit],(1)) else CONVERT([bit],(0)) end) PERSISTED,
	[error_type] [nvarchar](50) NULL,
	[max_retries] [int] NULL,
	[crm_received_date_time] [datetime2](7) NULL,
	[agent_version] [nvarchar](50) NULL,
	[taxonomy_version] [nvarchar](50) NULL,
	[prompt_version] [nvarchar](50) NULL,
	[agent_name] [nvarchar](100) NULL,
	[status_description]  AS (case TRY_CAST([status_code] AS [int]) when (1) then 'Email received from queue' when (2) then 'Email data pulled successfully' when (3) then 'Email data processed' when (4) then 'AI classification agent invoked' when (5) then 'Case payload created' when (6) then 'Case payload posted to CRM' when (8) then 'No case payload needed' when (9) then 'Processing failed' when (10) then 'Failed, no retry attempted' else 'Unrecognised status code' end) PERSISTED NOT NULL,
 CONSTRAINT [pk_email_instance] PRIMARY KEY CLUSTERED 
(
	[email_instance_id] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY],
 CONSTRAINT [uq_email_instance_activity_attempt] UNIQUE NONCLUSTERED 
(
	[activity_id] ASC,
	[attempt_number] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

ALTER TABLE [dbo].[cia_email_instance] ADD  CONSTRAINT [df_email_instance_id]  DEFAULT (newid()) FOR [email_instance_id]
GO

ALTER TABLE [dbo].[cia_email_instance] ADD  CONSTRAINT [df_email_instance_attempt_number]  DEFAULT ((1)) FOR [attempt_number]
GO

ALTER TABLE [dbo].[cia_email_instance] ADD  CONSTRAINT [df_email_instance_created_date_time]  DEFAULT (sysutcdatetime()) FOR [created_date_time]
GO

ALTER TABLE [dbo].[cia_email_instance] ADD  CONSTRAINT [df_email_instance_modified_date_time]  DEFAULT (sysutcdatetime()) FOR [modified_date_time]
GO

ALTER TABLE [dbo].[cia_email_instance] ADD  CONSTRAINT [df_email_instance_banker_modified_flag]  DEFAULT ((0)) FOR [banker_modified_flag]
GO

ALTER TABLE [dbo].[cia_email_instance]  WITH CHECK ADD  CONSTRAINT [ck_email_instance_last_completed_stage] CHECK  (([last_completed_stage] IS NULL OR ([last_completed_stage]='B9_post_case_creation' OR [last_completed_stage]='B8_make_payload' OR [last_completed_stage]='B7_decision' OR [last_completed_stage]='B6_invoke_agent_workflow' OR [last_completed_stage]='B5_parse_email' OR [last_completed_stage]='B4_data_pull_dataverse' OR [last_completed_stage]='B2_write_queue_item' OR [last_completed_stage]='B1_write_activity_id')))
GO

ALTER TABLE [dbo].[cia_email_instance] CHECK CONSTRAINT [ck_email_instance_last_completed_stage]
GO

ALTER TABLE [dbo].[cia_email_instance]  WITH CHECK ADD  CONSTRAINT [ck_email_instance_status_details_is_json] CHECK  (([status_details] IS NULL OR isjson([status_details])=(1)))
GO

ALTER TABLE [dbo].[cia_email_instance] CHECK CONSTRAINT [ck_email_instance_status_details_is_json]
GO

-------------------------------------

    CREATE TABLE dbo.cia_queue_item
(
    queue_item_id             UNIQUEIDENTIFIER   NOT NULL
        CONSTRAINT pk_queue_item PRIMARY KEY,

    activity_id                UNIQUEIDENTIFIER   NOT NULL,
    item_type                  NVARCHAR(50)       NULL,
    owner_id                   NVARCHAR(100)      NULL,
    regarding_id                UNIQUEIDENTIFIER   NULL,
    queue_id                    UNIQUEIDENTIFIER   NOT NULL,
    queue_name                   NVARCHAR(256)       NULL,
    worked_by                   NVARCHAR(512)       NULL,
      

    received_date_time           DATETIME2          NULL,
  
    processed_date_time           DATETIME2          NULL

    ))
);
GO

CREATE INDEX ix_queue_item_activity_id
    ON dbo.cia_queue_item (activity_id);
GO


