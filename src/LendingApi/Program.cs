using System.Reflection;
using LendingApi.Data;
using LendingApi.Loans;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

// "SqlServer" everywhere except local development and the tests, which use "InMemory".
var storageProvider = builder.Configuration["Storage:Provider"] ?? "SqlServer";
var healthChecks = builder.Services.AddHealthChecks();

if (storageProvider.Equals("InMemory", StringComparison.OrdinalIgnoreCase))
{
    builder.Services.AddSingleton<ILoanStore, InMemoryLoanStore>();
}
else
{
    // The connection string is not part of the package. The deployment injects it per environment.
    var connectionString = builder.Configuration.GetConnectionString("LendingDb")
        ?? throw new InvalidOperationException("Connection string 'LendingDb' is not configured.");

    builder.Services.AddDbContext<LendingDbContext>(options => options.UseSqlServer(connectionString));
    builder.Services.AddScoped<ILoanStore, SqlLoanStore>();
    healthChecks.AddCheck<DatabaseHealthCheck>("database");
}

var app = builder.Build();

// Liveness probe used by the deployment smoke test and by monitoring.
app.MapHealthChecks("/health");

// Reports which build is running, so a deployment can be verified after release.
app.MapGet("/version", (IHostEnvironment env) => new
{
    version = Assembly.GetExecutingAssembly()
        .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "unknown",
    environment = env.EnvironmentName,
    storage = storageProvider,
    machine = Environment.MachineName
});

var loans = app.MapGroup("/api/loans");

loans.MapGet("/", (ILoanStore store, CancellationToken ct) => store.GetAllAsync(ct));

loans.MapGet("/{id:guid}", async (Guid id, ILoanStore store, CancellationToken ct) =>
    await store.GetAsync(id, ct) is { } loan ? Results.Ok(loan) : Results.NotFound());

loans.MapPost("/", async (CreateLoanRequest request, ILoanStore store, CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(request.Borrower) || request.Principal <= 0 || request.TermMonths <= 0)
    {
        return Results.BadRequest(new { error = "Borrower, a positive principal and a positive term are required." });
    }

    var loan = await store.AddAsync(request, ct);
    return Results.Created($"/api/loans/{loan.Id}", loan);
});

app.Run();
