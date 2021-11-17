-- https://www.red-gate.com/simple-talk/sql/database-administration/pop-rivetts-sql-server-faq-no.5-pop-on-the-audit-trail/ 
-- Set up the tables
-- Firstly, we create the audit table.
-- There will only need to be one of these in a database

IF NOT EXISTS (SELECT * FROM sysobjects WHERE id = OBJECT_ID(N'[dbo].[audit]') 
               AND OBJECTPROPERTY(id, N'IsUserTable') = 1)
       CREATE TABLE [dbo].[audit]
               (Type CHAR(1), 
               TableName VARCHAR(128), 
               PK VARCHAR(1000), 
               FieldName VARCHAR(128), 
               OldValue VARCHAR(1000), 
               NewValue VARCHAR(1000), 
               UpdateDate datetime, 
               UserName VARCHAR(128))
GO

        -- -- now we will illustrate the use of this tool
        -- -- by creating a dummy test table called TrigTest. 

        -- IF EXISTS (SELECT * FROM sysobjects WHERE id = OBJECT_ID(N'[dbo].[trigtest]')
        --                 AND OBJECTPROPERTY(id, N'IsUserTable') = 1)
        -- DROP TABLE [dbo].[trigtest]
        -- GO
        -- CREATE TABLE trigtest 
        -- (i INT NOT NULL, 
        --         j INT NOT NULL, 
        --         s VARCHAR(10), 
        --         t VARCHAR(10))
        -- GO;

        -- --note that for this system to work there must be a primary key to the table
        -- --but then a table without a primary key isn't really a table is it?
        -- ALTER TABLE trigtest ADD CONSTRAINT pk PRIMARY KEY (i, j)
        -- GO;

--and now create the trigger itself. This has to be created for every
--table you want to monitor [schema].[table]

CREATE TRIGGER ut_audit ON [schema].[table] FOR INSERT, UPDATE, DELETE
AS

DECLARE @bit INT ,
       @field INT ,
       @maxfield INT ,
       @char INT ,
       @fieldname VARCHAR(128) ,
       @TableName VARCHAR(128) ,
       @PKCols VARCHAR(1000) ,
       @sql VARCHAR(2000), 
       @UpdateDate VARCHAR(21) ,
       @UserName VARCHAR(128) ,
       @Type CHAR(1) ,
       @PKSelect VARCHAR(1000)
       

--You will need to change @TableName to match the table to be audited
SELECT @TableName = '[schema].[table]'

-- date and user
SELECT 
        @UserName = SYSTEM_USER ,
        @UpdateDate = CONVERT(VARCHAR(8), GETDATE(), 112) + ' ' + CONVERT(VARCHAR(12), GETDATE(), 114)

-- Action
IF EXISTS (SELECT * FROM inserted)
       IF EXISTS (SELECT * FROM deleted)
               SELECT @Type = 'U'
       ELSE
               SELECT @Type = 'I'
ELSE
       SELECT @Type = 'D'

-- get list of columns
SELECT * INTO #ins FROM inserted
SELECT * INTO #del FROM deleted

-- Get primary key columns for full outer join
SELECT @PKCols = COALESCE(@PKCols + ' and', ' on') 
               + ' i.' + c.COLUMN_NAME + ' = d.' + c.COLUMN_NAME
       FROM    INFORMATION_SCHEMA.TABLE_CONSTRAINTS pk ,

              INFORMATION_SCHEMA.KEY_COLUMN_USAGE c
       WHERE   pk.TABLE_NAME = @TableName
       AND     CONSTRAINT_TYPE = 'PRIMARY KEY'
       AND     c.TABLE_NAME = pk.TABLE_NAME
       AND     c.CONSTRAINT_NAME = pk.CONSTRAINT_NAME

-- Get primary key select for insert
SELECT @PKSelect = COALESCE(@PKSelect+'+','') 
       + '''<' + COLUMN_NAME 
       + '=''+convert(varchar(100),
coalesce(i.' + COLUMN_NAME +',d.' + COLUMN_NAME + '))+''>''' 
       FROM    INFORMATION_SCHEMA.TABLE_CONSTRAINTS pk ,
               INFORMATION_SCHEMA.KEY_COLUMN_USAGE c
       WHERE   pk.TABLE_NAME = @TableName
       AND     CONSTRAINT_TYPE = 'PRIMARY KEY'
       AND     c.TABLE_NAME = pk.TABLE_NAME
       AND     c.CONSTRAINT_NAME = pk.CONSTRAINT_NAME

IF @PKCols IS NULL
BEGIN
       RAISERROR('no PK on table %s', 16, -1, @TableName)
       RETURN
END

SELECT         @field = 0, 
       @maxfield = MAX(ORDINAL_POSITION) 
       FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @TableName
WHILE @field < @maxfield
BEGIN
       SELECT @field = MIN(ORDINAL_POSITION) 
               FROM INFORMATION_SCHEMA.COLUMNS 
               WHERE TABLE_NAME = @TableName 
               AND ORDINAL_POSITION > @field
       SELECT @bit = (@field - 1 )% 8 + 1
       SELECT @bit = POWER(2,@bit - 1)
       SELECT @char = ((@field - 1) / 8) + 1
       IF SUBSTRING(COLUMNS_UPDATED(),@char, 1) & @bit > 0 OR @Type IN ('I','D')
       BEGIN
               SELECT @fieldname = COLUMN_NAME 
                       FROM INFORMATION_SCHEMA.COLUMNS 
                       WHERE TABLE_NAME = @TableName 
                       AND ORDINAL_POSITION = @field
               SELECT @sql = '
insert Audit (	Type, 
               TableName, 
               PK, 
               FieldName, 
               OldValue, 
               NewValue, 
               UpdateDate, 
               UserName)
select ''' + @Type + ''',''' 
       + @TableName + ''',' + @PKSelect
       + ',''' + @fieldname + ''''
       + ',convert(varchar(1000),d.' + @fieldname + ')'
       + ',convert(varchar(1000),i.' + @fieldname + ')'
       + ',''' + @UpdateDate + ''''
       + ',''' + @UserName + ''''
       + ' from #ins i full outer join #del d'
       + @PKCols
       + ' where i.' + @fieldname + ' <> d.' + @fieldname 
       + ' or (i.' + @fieldname + ' is null and  d.' + @fieldname + ' is not null)' 
       + ' or (i.' + @fieldname + ' is not null and  d.' + @fieldname + ' is null)' 
               EXEC (@sql)
       END
END

GO


-------------------------------------------------------

--now we can test the trigger out 

-- INSERT trigtest SELECT 1,1,'hi', 'bye'
-- INSERT trigtest SELECT 2,2,'hi', 'bye'
-- INSERT trigtest SELECT 3,3,'hi', 'bye'
-- SELECT * FROM Audit
-- SELECT * FROM trigtest
-- UPDATE trigtest SET s = 'hibye' WHERE i <> 1
-- UPDATE trigtest SET s = 'bye' WHERE i = 1
-- UPDATE trigtest SET s = 'bye' WHERE i = 1
-- UPDATE trigtest SET t = 'hi' WHERE i = 1
-- SELECT * FROM Audit
-- SELECT * FROM trigtest
-- DELETE trigtest
-- SELECT * FROM Audit
-- SELECT * FROM trigtest

-- GO


