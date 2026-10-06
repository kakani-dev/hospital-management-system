using Hms.Modules.Patients.Endpoints;

namespace Hms.UnitTests;

public class CreatePatientValidatorTests
{
    private static CreatePatientRequest Valid() =>
        new("ALP-1234", "Asha", "Synthetic", new DateOnly(1990, 1, 1), "female", Guid.NewGuid(), null, "asha@patients.example");

    [Fact]
    public void Valid_request_has_no_errors() => Assert.Empty(CreatePatientValidator.Validate(Valid()));

    [Theory]
    [InlineData("")]
    [InlineData("has space")]
    [InlineData("THIS-MRN-IS-WAY-TOO-LONG-1234567890")]
    [InlineData("drop;table")]
    public void Invalid_mrn_is_rejected(string mrn) =>
        Assert.Contains("mrn", CreatePatientValidator.Validate(Valid() with { Mrn = mrn }).Keys);

    [Fact]
    public void Multiple_errors_are_reported_together()
    {
        var errors = CreatePatientValidator.Validate(Valid() with { FirstName = " ", Sex = "x", RegisteredBranchId = Guid.Empty, DateOfBirth = new DateOnly(1800, 1, 1) });
        Assert.Equal(["dateOfBirth", "firstName", "registeredBranchId", "sex"], errors.Keys.Order(StringComparer.Ordinal));
    }
}
