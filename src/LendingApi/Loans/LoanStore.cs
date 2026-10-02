using System.Collections.Concurrent;
using LendingApi.Data;
using Microsoft.EntityFrameworkCore;

namespace LendingApi.Loans;

public interface ILoanStore
{
    Task<IReadOnlyCollection<Loan>> GetAllAsync(CancellationToken ct);
    Task<Loan?> GetAsync(Guid id, CancellationToken ct);
    Task<Loan> AddAsync(CreateLoanRequest request, CancellationToken ct);
}

// Used in every deployed environment. The schema is owned by the scripts in db/migrations.
public class SqlLoanStore(LendingDbContext db) : ILoanStore
{
    public async Task<IReadOnlyCollection<Loan>> GetAllAsync(CancellationToken ct) =>
        await db.Loans.AsNoTracking().OrderBy(l => l.CreatedAt).ToListAsync(ct);

    public Task<Loan?> GetAsync(Guid id, CancellationToken ct) =>
        db.Loans.AsNoTracking().FirstOrDefaultAsync(l => l.Id == id, ct);

    public async Task<Loan> AddAsync(CreateLoanRequest request, CancellationToken ct)
    {
        var loan = Loan.Create(request);
        db.Loans.Add(loan);
        await db.SaveChangesAsync(ct);
        return loan;
    }
}

// Used for local development and the tests, so neither needs a database.
public class InMemoryLoanStore : ILoanStore
{
    private readonly ConcurrentDictionary<Guid, Loan> _loans = new();

    public InMemoryLoanStore()
    {
        Add(new CreateLoanRequest("Nordic Shipping AS", 25_000_000m, "NOK", 60));
        Add(new CreateLoanRequest("Fjord Energy AB", 8_500_000m, "SEK", 36));
    }

    public Task<IReadOnlyCollection<Loan>> GetAllAsync(CancellationToken ct) =>
        Task.FromResult<IReadOnlyCollection<Loan>>(_loans.Values.OrderBy(l => l.CreatedAt).ToList());

    public Task<Loan?> GetAsync(Guid id, CancellationToken ct) => Task.FromResult(_loans.GetValueOrDefault(id));

    public Task<Loan> AddAsync(CreateLoanRequest request, CancellationToken ct) => Task.FromResult(Add(request));

    private Loan Add(CreateLoanRequest request)
    {
        var loan = Loan.Create(request);
        _loans[loan.Id] = loan;
        return loan;
    }
}
