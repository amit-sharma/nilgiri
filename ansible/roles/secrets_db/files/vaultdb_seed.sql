-- vaultdb_seed.sql -- M9 final target DB (layered stored-procedure injection).
-- sqlcmd vars: $(BridgeUser) $(BridgePass) $(FlagS2) $(FlagS3) $(FlagS4)
--
-- The bridge login (M8 handoff) can EXEC dbo.usp_LookupAsset and SELECT
-- dbo.Assets, nothing else. Each layer unlocks the next:
--   LAYER A  @name  -> UNION dbo.AppConfig      (m9.s2)
--   LAYER B  @mode  -> nested EXEC usp_AuditAccess w/ caller-controlled
--                      @actor -> dbo.AuditVault (m9.s3)
--   LAYER C  @actor -> UNION dbo.TargetSecrets  (m9.s4, the objective)
-- usp_LookupAsset runs EXECUTE AS 'vault_reader' (Assets + AppConfig only), so
-- @name injection is confined to LAYER A; the protected tables are reachable
-- only in dbo context, which only usp_AuditAccess runs in -- blocking the
-- stacked shortcut `@name = N'x''; SELECT * FROM dbo.TargetSecrets--'`.

IF DB_ID('VaultDb') IS NULL CREATE DATABASE VaultDb;
GO
USE VaultDb;
GO

-- Limited bridge login (the M8 handoff credential). NOT db_owner, NOT sysadmin.
IF SUSER_ID('$(BridgeUser)') IS NULL
    CREATE LOGIN [$(BridgeUser)] WITH PASSWORD = '$(BridgePass)', CHECK_POLICY = OFF;
IF USER_ID('$(BridgeUser)') IS NULL
    CREATE USER [$(BridgeUser)] FOR LOGIN [$(BridgeUser)];
GO

-- Restricted execution context for the entry proc (NOT a login): usp_LookupAsset's
-- @name dynamic SQL runs with rights to dbo.Assets + dbo.AppConfig but NOT the
-- protected tables, confining @name injection to LAYER A.
IF USER_ID('vault_reader') IS NULL
    CREATE USER vault_reader WITHOUT LOGIN;
GO

-- Tables ------------------------------------------------------------------
IF OBJECT_ID('dbo.Assets') IS NOT NULL DROP TABLE dbo.Assets;
CREATE TABLE dbo.Assets (id INT IDENTITY PRIMARY KEY, name NVARCHAR(200), value NVARCHAR(400));
INSERT INTO dbo.Assets (name, value) VALUES
 (N'fleet-01', N'alpha deploy node'),
 (N'fleet-02', N'alpha build node'),
 (N'vault-db', N'records vault primary');
GO

-- LAYER A target (reached by UNION through usp_LookupAsset @name).
IF OBJECT_ID('dbo.AppConfig') IS NOT NULL DROP TABLE dbo.AppConfig;
CREATE TABLE dbo.AppConfig (id INT IDENTITY PRIMARY KEY, cfgkey NVARCHAR(100), cfgval NVARCHAR(400));
INSERT INTO dbo.AppConfig (cfgkey, cfgval) VALUES
 (N'audit.proc',     N'dbo.usp_AuditAccess -- callable only via usp_LookupAsset @mode'),
 (N'vault.token.s2', N'$(FlagS2)');
GO

-- LAYER B target (reached by the nested EXEC of usp_AuditAccess @actor).
IF OBJECT_ID('dbo.AuditVault') IS NOT NULL DROP TABLE dbo.AuditVault;
CREATE TABLE dbo.AuditVault (id INT IDENTITY PRIMARY KEY, actor NVARCHAR(200), note NVARCHAR(400));
INSERT INTO dbo.AuditVault (actor, note) VALUES
 (N'system',      N'routine audit'),
 (N'maintenance', N'$(FlagS3)');
GO

-- LAYER C target -- the objective. Owner-only; the bridge user is DENY'd.
IF OBJECT_ID('dbo.TargetSecrets') IS NOT NULL DROP TABLE dbo.TargetSecrets;
CREATE TABLE dbo.TargetSecrets (id INT IDENTITY PRIMARY KEY, label NVARCHAR(200), secret NVARCHAR(400));
INSERT INTO dbo.TargetSecrets (label, secret) VALUES
 (N'records-vault-export', N'$(FlagS4)');
GO

-- Nested audit proc. EXECUTE AS OWNER -> its dynamic SELECT runs as dbo, so an
-- injected UNION reaches dbo.TargetSecrets (LAYER C / m9.s4).
CREATE OR ALTER PROCEDURE dbo.usp_AuditAccess @actor NVARCHAR(200)
WITH EXECUTE AS OWNER
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @q NVARCHAR(MAX) =
    N'SELECT actor, note FROM dbo.AuditVault WHERE actor = N''' + @actor + N'''';
  EXEC sp_executesql @q;
END;
GO

-- Entry proc the maintenance script calls. EXECUTE AS 'vault_reader' (NOT OWNER).
--   LAYER A (m9.s2): @name concatenated into a SELECT over dbo.Assets; a UNION
--                    reaches dbo.AppConfig.
--   LAYER B (m9.s3): @mode concatenated into a nested EXEC of usp_AuditAccess
--                    (EXECUTE AS OWNER -> dbo), which the bridge user is DENY'd
--                    from calling directly.
CREATE OR ALTER PROCEDURE dbo.usp_LookupAsset @name NVARCHAR(200), @mode NVARCHAR(200) = N'read'
WITH EXECUTE AS 'vault_reader'
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @sql NVARCHAR(MAX) =
    N'SELECT name, value FROM dbo.Assets WHERE name = N''' + @name + N'''';
  EXEC sp_executesql @sql;
  DECLARE @acall NVARCHAR(MAX) =
    N'EXEC dbo.usp_AuditAccess @actor = N''' + @mode + N'''';
  EXEC sp_executesql @acall;
END;
GO

-- Grants: the bridge login can ONLY EXEC the entry proc + read Assets.
GRANT EXECUTE ON dbo.usp_LookupAsset TO [$(BridgeUser)];
GRANT SELECT  ON OBJECT::dbo.Assets  TO [$(BridgeUser)];
DENY  SELECT  ON OBJECT::dbo.AppConfig     TO [$(BridgeUser)];
DENY  SELECT  ON OBJECT::dbo.AuditVault    TO [$(BridgeUser)];
DENY  SELECT  ON OBJECT::dbo.TargetSecrets TO [$(BridgeUser)];
DENY  EXECUTE ON dbo.usp_AuditAccess       TO [$(BridgeUser)];
GO

-- vault_reader = usp_LookupAsset's execution context: reaches LAYER A (Assets +
-- AppConfig) and can invoke the audit proc, but is DENY'd the protected tables.
-- Dynamic SQL breaks ownership chaining, so these direct grants/denies are what
-- gate the @name surface.
GRANT SELECT  ON OBJECT::dbo.Assets        TO vault_reader;
GRANT SELECT  ON OBJECT::dbo.AppConfig      TO vault_reader;
GRANT EXECUTE ON dbo.usp_AuditAccess        TO vault_reader;
DENY  SELECT  ON OBJECT::dbo.AuditVault     TO vault_reader;
DENY  SELECT  ON OBJECT::dbo.TargetSecrets  TO vault_reader;
GO

PRINT 'VaultDb seeded';
GO
