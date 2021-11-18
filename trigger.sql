/*this is a journey... 
    Source links:

    https://www.red-gate.com/simple-talk/databases/sql-server/database-administration-sql-server/pop-rivetts-sql-server-faq-no-5-pop-on-the-audit-trail/ 
    https://stackoverflow.com/questions/19737723/log-record-changes-in-sql-server-in-an-audit-table
    https://chat.stackexchange.com/transcript/message/34774768#34774768 
    http://jsbin.com/lafayiluri/1/edit?html,output 
*/

-- #region | Set up the tables
/*Firstly, we create the audit table.
There will only need to be one of these in a database*/
DROP TABLE IF EXISTS dbo.audit_trigger; 
CREATE TABLE dbo.audit_trigger (
    audit_trigger_id INT IDENTITY(1,1) PRIMARY KEY NOT NULL, 
    audit_type CHAR(1),
    table_name VARCHAR(128),
    PK VARCHAR(1000),
    field_name VARCHAR(128),
    old_value VARCHAR(1000),
    new_value VARCHAR(1000),
    update_date datetime,
    audit_user_name VARCHAR(128)
);
GO
/*now we will illustrate the use of this tool
by creating a dummy test table called TrigTest.*/
DROP TABLE IF EXISTS dbo.trigtest;
CREATE TABLE trigtest (
    i INT NOT NULL,
    j INT NOT NULL,
    s VARCHAR(10),
    t VARCHAR(10)
);
GO

/*note that for this system to work there must be a primary key
to the table but then a table without a primary key
isn’t really a table is it?*/
ALTER TABLE trigtest ADD CONSTRAINT pk PRIMARY KEY (i, j);
GO
-- #endregion 

/*and now create the trigger itself. This has to be created for every
table you want to monitor*/

-- #region | trigger with bug fix
DROP TRIGGER IF EXISTS dbo.tr_audit_trigtest;
GO
CREATE TRIGGER tr_audit_trigtest ON dbo.trigtest 
    FOR  
        /*uncomment INSERT if you want. The insert data is on the source table
            but sometimes your end users wanna see ALL the data in the audit table
            and hey, storage is cheap-ish now /shrug    
        */
        -- INSERT, 
        UPDATE, 
        DELETE 
AS
SET NOCOUNT ON;
/*declare all the variables*/
DECLARE @bit INT;
DECLARE @field INT;
DECLARE @maxfield INT;
DECLARE @char INT;
DECLARE @fieldname VARCHAR(128);
DECLARE @TableName VARCHAR(128);
DECLARE @PKCols VARCHAR(1000);
DECLARE @sql VARCHAR(2000);
DECLARE @UpdateDate VARCHAR(21);
DECLARE @UserName VARCHAR(128);
DECLARE @Type CHAR(1);
DECLARE @PKSelect VARCHAR(1000);

/*now set some of these variables*/
SET @TableName = (
    SELECT 
        OBJECT_NAME(parent_object_id) 
    FROM sys.objects
    WHERE 
        sys.objects.name = OBJECT_NAME(@@PROCID)
);
SET @UserName = SYSTEM_USER;
SET @UpdateDate = CONVERT(NVARCHAR(30), GETDATE(), 126);

/*Action*/
IF EXISTS (SELECT * FROM INSERTED)
    IF EXISTS (SELECT * FROM DELETED)
         SET @Type = 'U'
    ELSE SET @Type = 'I'
    ELSE SET @Type = 'D'
;
/*get list of columns*/
SELECT * 
INTO #ins
FROM INSERTED;

SELECT * 
INTO #del
FROM DELETED;

/*set @PKCols and @PKSelect via SELECT statement.*/
SELECT @PKCols = /*Get primary key columns for full outer join*/
        COALESCE(@PKCols + ' and', ' on') 
        + ' i.[' + c.COLUMN_NAME + '] = d.[' + c.COLUMN_NAME + ']'
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS AS pk
        INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS c ON (
            c.TABLE_NAME = pk.TABLE_NAME
            AND c.CONSTRAINT_NAME = pk.CONSTRAINT_NAME
        )
    WHERE pk.TABLE_NAME = @TableName
        AND CONSTRAINT_TYPE = 'PRIMARY KEY'
;
SELECT @PKSelect = /*Get primary key select for insert*/
        COALESCE(@PKSelect + '+', '') 
        + '''<[' + COLUMN_NAME + ']=''+convert(varchar(100),
        coalesce(i.[' + COLUMN_NAME + '],d.[' + COLUMN_NAME + ']))+''>'''
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS pk,
        INFORMATION_SCHEMA.KEY_COLUMN_USAGE c
    WHERE  pk.TABLE_NAME = @TableName
        AND CONSTRAINT_TYPE = 'PRIMARY KEY'
        AND c.TABLE_NAME = pk.TABLE_NAME
        AND c.CONSTRAINT_NAME = pk.CONSTRAINT_NAME
;
IF @PKCols IS NULL
BEGIN
    RAISERROR('no PK on table %s', 16, -1, @TableName);
    RETURN;
END

SET @field = 0;
SET @maxfield = (
    SELECT 
        MAX(
            COLUMNPROPERTY(
                OBJECT_ID(TABLE_SCHEMA + '.' + @TableName),
                COLUMN_NAME,
                'ColumnID'
            )
        )
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE  
        TABLE_NAME = @TableName
);

WHILE @field < @maxfield
BEGIN
    SET @field = (
        SELECT 
            MIN(
                COLUMNPROPERTY(
                    OBJECT_ID(TABLE_SCHEMA + '.' + @TableName),
                    COLUMN_NAME,
                    'ColumnID'
                )
            )
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE  
            TABLE_NAME = @TableName
            AND COLUMNPROPERTY(
                    OBJECT_ID(TABLE_SCHEMA + '.' + @TableName),
                    COLUMN_NAME,
                    'ColumnID'
                ) > @field
    );
    SET @bit = (@field - 1)% 8 + 1;
    SET @bit = POWER(2, @bit - 1);
    SET @char = ((@field - 1) / 8) + 1;

    IF (
        SUBSTRING(COLUMNS_UPDATED(), @char, 1) & @bit > 0
        OR @Type IN ('I', 'D')
    )
    BEGIN
        SET @fieldname = (
            SELECT 
                COLUMN_NAME
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE  
                TABLE_NAME = @TableName
                AND COLUMNPROPERTY(
                        OBJECT_ID(TABLE_SCHEMA + '.' + @TableName),
                        COLUMN_NAME,
                        'ColumnID'
                    ) = @field
        );
        SET @sql = ('
            INSERT INTO audit_trigger (    
                audit_type, 
                table_name, 
                PK, 
                field_name, 
                old_value, 
                new_value, 
                update_date, 
                audit_user_name
            )
            SELECT ''' 
                + @Type + ''',''' 
                + @TableName + ''',' 
                + @PKSelect + ',''' 
                + @fieldname + ''''
                + ',convert(varchar(1000),d.' + @fieldname + ')'
                + ',convert(varchar(1000),i.' + @fieldname + ')'
                + ',''' + @UpdateDate + ''''
                + ',''' + @UserName + '''' + 
            ' FROM #ins AS i FULL OUTER JOIN #del AS d'
                    + @PKCols + 
            ' WHERE i.' + @fieldname + ' <> d.' + @fieldname 
                    + ' or (i.' + @fieldname + ' is null and  d.'
                    + @fieldname
                    + ' is not null)' 
                    + ' or (i.' + @fieldname + ' is not null and  d.' 
                    + @fieldname
                    + ' is null)' 
        );
        EXEC (@sql)
    END
END
SET NOCOUNT OFF;
GO 
-- #endregion 


-- #region | now we can test the trigger out
INSERT trigtest SELECT 1,1,'hi', 'bye';
INSERT trigtest SELECT 2,2,'hi', 'bye';
INSERT trigtest SELECT 3,3,'hi', 'bye';
SELECT * FROM dbo.audit_trigger;
SELECT * FROM trigtest;
UPDATE trigtest SET s = 'hibye' WHERE i <> 1;
UPDATE trigtest SET s = 'bye' WHERE i = 1;
UPDATE trigtest SET s = 'bye' WHERE i = 1;
UPDATE trigtest SET t = 'hi' WHERE i = 1;
SELECT * FROM dbo.audit_trigger;
SELECT * FROM dbo.trigtest;
DELETE dbo.trigtest;
SELECT * FROM dbo.audit_trigger;
SELECT * FROM dbo.trigtest;
GO

DROP TABLE dbo.audit_trigger;
GO
DROP TABLE dbo.trigtest ;
GO
-- #endregion
