using LendingApi.Loans;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace LendingApi.Data;

// Maps to the schema created by the scripts in db/migrations. EF Core migrations are not used.
public class LendingDbContext(DbContextOptions<LendingDbContext> options) : DbContext(options)
{
    public DbSet<Loan> Loans => Set<Loan>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Loan>(loan =>
        {
            loan.ToTable("Loans");
            loan.HasKey(l => l.Id);
            loan.Property(l => l.Id).ValueGeneratedNever();
            loan.Property(l => l.Borrower).HasMaxLength(200);
            loan.Property(l => l.Principal).HasPrecision(18, 2);
            loan.Property(l => l.Currency).HasColumnType("char(3)");
            loan.Property(l => l.Status).HasMaxLength(20).IsUnicode(false);
        });
    }
}

// Reads from the Loans table, so it fails when the database is unreachable, the schema
// is missing, or the app identity has no read access.
public class DatabaseHealthCheck(LendingDbContext db) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            await db.Loans.AnyAsync(cancellationToken);
            return HealthCheckResult.Healthy();
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy("The database check failed.", ex);
        }
    }
}
