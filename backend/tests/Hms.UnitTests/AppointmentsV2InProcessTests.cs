using System.Net;
using System.Net.Http.Json;
using Hms.Modules.Appointments.Domain;
using Hms.Modules.Appointments.Endpoints;
using Hms.Modules.Appointments.Persistence;
using Hms.SharedKernel.Tenancy;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.Extensions.DependencyInjection;
using static Hms.UnitTests.InProcessApiTests;

namespace Hms.UnitTests;

/// <summary>API v2 additions: embedded patient (single JOIN) and GET /practitioners?branchId=.</summary>
public sealed class AppointmentsV2InProcessTests(ApiFactory factory) : IClassFixture<ApiFactory>
{
    private sealed record PatientRefBody(Guid Id, string Mrn, string FirstName, string LastName);

    private sealed record AppointmentBody(Guid Id, Guid PatientId, PatientRefBody? Patient);

    private sealed record PageBody(List<AppointmentBody> Items);

    private sealed record QueueBody(Guid Id, Guid PatientId, PatientRefBody? Patient);

    private sealed record PractitionerBody(Guid Id);

    private static AppointmentsDbContext NpgsqlModelOnly() =>
        new(new DbContextOptionsBuilder<AppointmentsDbContext>().UseNpgsql("Host=unused").UseSnakeCaseNamingConvention().Options, new TenantContext());

    [Fact]
    public void Embedding_is_one_statement_with_a_left_join_on_visible_patients()
    {
        using var db = NpgsqlModelOnly();
        var appointments = db.Appointments.AsNoTracking().WithPatient(db).OrderBy(r => r.Appointment.StartsAt).Take(25).ToQueryString();
        var queue = db.QueueEntries.AsNoTracking().WithPatient(db).ToQueryString();
        foreach (var sql in new[] { appointments, queue })
        {
            Assert.Contains("LEFT JOIN", sql, StringComparison.Ordinal);
            Assert.Contains("FROM patient.patients", sql, StringComparison.Ordinal);
            Assert.Contains("deleted_at IS NULL", sql, StringComparison.Ordinal);
            Assert.DoesNotContain(";", sql.TrimEnd().TrimEnd(';'), StringComparison.Ordinal); // a single statement
        }
    }

    [Fact]
    public void PatientRef_is_read_only_and_not_part_of_migrations()
    {
        using var db = NpgsqlModelOnly();
        var entity = db.GetService<Microsoft.EntityFrameworkCore.Metadata.IDesignTimeModel>().Model.FindEntityType(typeof(PatientRef))!;
        Assert.Equal("patient", entity.GetSchema());
        Assert.Equal("patients", entity.GetTableName());
        Assert.True(entity.IsTableExcludedFromMigrations());
        Assert.All(entity.GetProperties().Where(p => !p.IsKey()), p =>
        {
            Assert.Equal(Microsoft.EntityFrameworkCore.Metadata.PropertySaveBehavior.Ignore, p.GetBeforeSaveBehavior());
            Assert.Equal(Microsoft.EntityFrameworkCore.Metadata.PropertySaveBehavior.Ignore, p.GetAfterSaveBehavior());
        });
    }

    private async Task<(Guid Live, Guid Deleted)> SeedPatientsAsync()
    {
        using var scope = factory.Services.CreateScope();
        ((TenantContext)scope.ServiceProvider.GetRequiredService<ITenantContext>())
            .Resolve(Alpha, Admin, null, [HmsRoles.TenantAdmin], [Main, East]);
        var db = scope.ServiceProvider.GetRequiredService<AppointmentsDbContext>();
        var live = new PatientRef { Id = Guid.NewGuid(), TenantId = Alpha, Mrn = "V2-LIVE", FirstName = "Asha", LastName = "Rao" };
        var deleted = new PatientRef { Id = Guid.NewGuid(), TenantId = Alpha, Mrn = "V2-DEL", FirstName = "Old", LastName = "Gone", DeletedAt = Now };
        db.Set<PatientRef>().AddRange(live, deleted);
        await db.SaveChangesAsync();
        return (live.Id, deleted.Id);
    }

    [Fact]
    public async Task Appointment_and_queue_responses_carry_the_patient()
    {
        var (live, deleted) = await SeedPatientsAsync();
        using var admin = factory.ClientAs(Admin);
        var pr = (await (await admin.PostAsJsonAsync("/api/v1/practitioners", new { displayName = "Dr. V2" })).Content.ReadFromJsonAsync<PractitionerBody>())!;
        var start = new DateTimeOffset(2031, 4, 7, 10, 0, 0, TimeSpan.Zero);

        async Task<AppointmentBody> Book(Guid patient, int offset)
        {
            var response = await admin.PostAsJsonAsync("/api/v1/appointments", new
            {
                branchId = Main, practitionerId = pr.Id, patientId = patient, startsAt = start.AddHours(offset), endsAt = start.AddHours(offset).AddMinutes(15),
            });
            Assert.Equal(HttpStatusCode.Created, response.StatusCode);
            return (await response.Content.ReadFromJsonAsync<AppointmentBody>())!;
        }

        var withLive = await Book(live, 0);
        Assert.Equal(new PatientRefBody(live, "V2-LIVE", "Asha", "Rao"), withLive.Patient);
        var withDeleted = await Book(deleted, 1);
        Assert.Null(withDeleted.Patient);
        Assert.Null((await Book(Guid.NewGuid(), 2)).Patient); // unknown / unreadable patient

        var page = (await admin.GetFromJsonAsync<PageBody>($"/api/v1/appointments?practitionerId={pr.Id}"))!;
        Assert.Equal(3, page.Items.Count);
        Assert.Equal("V2-LIVE", page.Items.Single(a => a.Id == withLive.Id).Patient!.Mrn);
        Assert.Null(page.Items.Single(a => a.Id == withDeleted.Id).Patient);
        Assert.Equal("Rao", (await admin.GetFromJsonAsync<AppointmentBody>($"/api/v1/appointments/{withLive.Id}"))!.Patient!.LastName);

        // queue board (rows written by the DB in production; seeded directly here)
        using (var scope = factory.Services.CreateScope())
        {
            ((TenantContext)scope.ServiceProvider.GetRequiredService<ITenantContext>())
                .Resolve(Alpha, Admin, null, [HmsRoles.TenantAdmin], [Main, East]);
            var db = scope.ServiceProvider.GetRequiredService<AppointmentsDbContext>();
            db.QueueEntries.Add(new QueueEntry
            {
                Id = Guid.NewGuid(), TenantId = Alpha, BranchId = East, QueueDate = new DateOnly(2031, 4, 7), TokenNo = 1, PatientId = live,
                Status = QueueStatus.Waiting, CheckedInAt = start,
            });
            await db.SaveChangesAsync();
        }

        var board = (await admin.GetFromJsonAsync<List<QueueBody>>($"/api/v1/queue?branchId={East}&date=2031-04-07"))!;
        Assert.Equal("V2-LIVE", Assert.Single(board).Patient!.Mrn);
    }

    [Fact]
    public async Task Practitioners_filter_by_active_schedule_at_branch()
    {
        using var admin = factory.ClientAs(Admin);
        async Task<Guid> Practitioner() =>
            (await (await admin.PostAsJsonAsync("/api/v1/practitioners", new { displayName = "Dr. Filter" })).Content.ReadFromJsonAsync<PractitionerBody>())!.Id;

        var main = await Practitioner();
        var east = await Practitioner();
        var ended = await Practitioner();
        Assert.Equal(HttpStatusCode.Created, (await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = main, branchId = Main, weekday = 2, startTime = "09:00", endTime = "10:00" })).StatusCode);
        Assert.Equal(HttpStatusCode.Created, (await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = east, branchId = East, weekday = 2, startTime = "09:00", endTime = "10:00" })).StatusCode);
        Assert.Equal(HttpStatusCode.Created, (await admin.PostAsJsonAsync("/api/v1/schedules", new { practitionerId = ended, branchId = Main, weekday = 2, startTime = "09:00", endTime = "10:00", validFrom = "2025-01-01", validTo = "2026-01-01" })).StatusCode);

        var atMain = (await admin.GetFromJsonAsync<List<PractitionerBody>>($"/api/v1/practitioners?branchId={Main}"))!.Select(p => p.Id).ToList();
        Assert.Contains(main, atMain);
        Assert.DoesNotContain(east, atMain);
        Assert.DoesNotContain(ended, atMain);
        var all = (await admin.GetFromJsonAsync<List<PractitionerBody>>("/api/v1/practitioners"))!.Select(p => p.Id).ToList();
        Assert.Contains(east, all);
        Assert.Contains(ended, all);

        Assert.Equal(HttpStatusCode.NotFound, (await admin.GetAsync($"/api/v1/practitioners?branchId={BetaMain}")).StatusCode);
    }
}
