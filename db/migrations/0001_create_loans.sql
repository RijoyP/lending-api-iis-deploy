CREATE TABLE dbo.Loans
(
    Id         uniqueidentifier NOT NULL CONSTRAINT PK_Loans PRIMARY KEY,
    Borrower   nvarchar(200)    NOT NULL,
    Principal  decimal(18, 2)   NOT NULL,
    Currency   char(3)          NOT NULL,
    TermMonths int              NOT NULL,
    CreatedAt  datetimeoffset   NOT NULL
);
GO

CREATE INDEX IX_Loans_CreatedAt ON dbo.Loans (CreatedAt);
GO
