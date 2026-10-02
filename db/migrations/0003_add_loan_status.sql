-- Backward compatible: the column has a default, so a release that does not know about
-- Status can still insert loans. That keeps a code rollback safe after this script has run.
ALTER TABLE dbo.Loans
    ADD Status varchar(20) NOT NULL CONSTRAINT DF_Loans_Status DEFAULT 'Active';
GO
