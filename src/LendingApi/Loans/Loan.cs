namespace LendingApi.Loans;

public record Loan(Guid Id, string Borrower, decimal Principal, string Currency, int TermMonths, DateTimeOffset CreatedAt);

public record CreateLoanRequest(string Borrower, decimal Principal, string Currency, int TermMonths);
