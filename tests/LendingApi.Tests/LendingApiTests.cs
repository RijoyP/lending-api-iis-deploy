using System.Net;
using System.Net.Http.Json;
using LendingApi.Loans;
using Microsoft.AspNetCore.Mvc.Testing;

namespace LendingApi.Tests;

public class LendingApiTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client;

    public LendingApiTests(WebApplicationFactory<Program> factory)
    {
        _client = factory.CreateClient();
    }

    [Fact]
    public async Task Health_ReturnsHealthy()
    {
        var response = await _client.GetAsync("/health");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("Healthy", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Version_ReturnsVersionAndEnvironment()
    {
        var body = await _client.GetFromJsonAsync<Dictionary<string, string>>("/version");

        Assert.NotNull(body);
        Assert.False(string.IsNullOrWhiteSpace(body["version"]));
        Assert.False(string.IsNullOrWhiteSpace(body["environment"]));
    }

    [Fact]
    public async Task GetLoans_ReturnsSeededLoans()
    {
        var loans = await _client.GetFromJsonAsync<List<Loan>>("/api/loans");

        Assert.NotNull(loans);
        Assert.True(loans.Count >= 2);
    }

    [Fact]
    public async Task CreateLoan_ThenGetById_ReturnsTheLoan()
    {
        var request = new CreateLoanRequest("Bergen Export AS", 1_200_000m, "nok", 24);

        var created = await _client.PostAsJsonAsync("/api/loans", request);
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);

        var loan = await created.Content.ReadFromJsonAsync<Loan>();
        Assert.NotNull(loan);
        Assert.Equal("NOK", loan.Currency);

        var fetched = await _client.GetFromJsonAsync<Loan>($"/api/loans/{loan.Id}");
        Assert.Equal(loan, fetched);
    }

    [Fact]
    public async Task CreateLoan_WithInvalidPrincipal_ReturnsBadRequest()
    {
        var request = new CreateLoanRequest("Bergen Export AS", 0m, "NOK", 24);

        var response = await _client.PostAsJsonAsync("/api/loans", request);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task GetLoan_UnknownId_ReturnsNotFound()
    {
        var response = await _client.GetAsync($"/api/loans/{Guid.NewGuid()}");

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }
}
