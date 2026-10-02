using System.Collections.Concurrent;

namespace LendingApi.Loans;

public interface ILoanStore
{
    IReadOnlyCollection<Loan> GetAll();
    Loan? Get(Guid id);
    Loan Add(CreateLoanRequest request);
}

// In-memory store to keep the sample focused on build, release and deployment.
// Data is lost when the app pool recycles.
public class InMemoryLoanStore : ILoanStore
{
    private readonly ConcurrentDictionary<Guid, Loan> _loans = new();

    public InMemoryLoanStore()
    {
        Add(new CreateLoanRequest("Nordic Shipping AS", 25_000_000m, "NOK", 60));
        Add(new CreateLoanRequest("Fjord Energy AB", 8_500_000m, "SEK", 36));
    }

    public IReadOnlyCollection<Loan> GetAll() => _loans.Values.OrderBy(l => l.CreatedAt).ToList();

    public Loan? Get(Guid id) => _loans.GetValueOrDefault(id);

    public Loan Add(CreateLoanRequest request)
    {
        var loan = new Loan(
            Guid.NewGuid(),
            request.Borrower.Trim(),
            request.Principal,
            string.IsNullOrWhiteSpace(request.Currency) ? "NOK" : request.Currency.Trim().ToUpperInvariant(),
            request.TermMonths,
            DateTimeOffset.UtcNow);

        _loans[loan.Id] = loan;
        return loan;
    }
}
