namespace LendingApi.Loans;

public record Loan(Guid Id, string Borrower, decimal Principal, string Currency, int TermMonths, DateTimeOffset CreatedAt, string Status)
{
    public static Loan Create(CreateLoanRequest request) => new(
        Guid.NewGuid(),
        request.Borrower.Trim(),
        request.Principal,
        string.IsNullOrWhiteSpace(request.Currency) ? "NOK" : request.Currency.Trim().ToUpperInvariant(),
        request.TermMonths,
        DateTimeOffset.UtcNow,
        "Active");
}

public record CreateLoanRequest(string Borrower, decimal Principal, string Currency, int TermMonths);
