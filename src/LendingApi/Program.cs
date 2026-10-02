using System.Reflection;
using LendingApi.Loans;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSingleton<ILoanStore, InMemoryLoanStore>();
builder.Services.AddHealthChecks();

var app = builder.Build();

// Liveness probe used by the deployment smoke test and by monitoring.
app.MapHealthChecks("/health");

// Reports which build is running, so a deployment can be verified after release.
app.MapGet("/version", (IHostEnvironment env) => new
{
    version = Assembly.GetExecutingAssembly()
        .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "unknown",
    environment = env.EnvironmentName,
    machine = Environment.MachineName
});

var loans = app.MapGroup("/api/loans");

loans.MapGet("/", (ILoanStore store) => store.GetAll());

loans.MapGet("/{id:guid}", (Guid id, ILoanStore store) =>
    store.Get(id) is { } loan ? Results.Ok(loan) : Results.NotFound());

loans.MapPost("/", (CreateLoanRequest request, ILoanStore store) =>
{
    if (string.IsNullOrWhiteSpace(request.Borrower) || request.Principal <= 0 || request.TermMonths <= 0)
    {
        return Results.BadRequest(new { error = "Borrower, a positive principal and a positive term are required." });
    }

    var loan = store.Add(request);
    return Results.Created($"/api/loans/{loan.Id}", loan);
});

app.Run();
