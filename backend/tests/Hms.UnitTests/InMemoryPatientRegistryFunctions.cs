using Hms.Modules.Patients.Domain;
using Hms.Modules.Patients.Endpoints;
using Hms.Modules.Patients.Persistence;
using Hms.Modules.Patients.Registry;
using Hms.SharedKernel.Tenancy;
using Microsoft.EntityFrameworkCore;

namespace Hms.UnitTests;

/// <summary>
/// Unit-test stand-in for the DB registry RPCs (SPRINT2-CONTRACT §1.3/§1.5) over EF InMemory. It
/// mirrors the documented rules closely enough to exercise the endpoints; the real functions are
/// covered by Hms.IntegrationTests and the SQL tests.
/// </summary>
internal sealed class InMemoryPatientRegistryFunctions(PatientsDbContext db, ITenantContext tenant, TimeProvider clock) : IPatientRegistryFunctions
{
    public async Task<IReadOnlyList<DuplicateCandidateDto>> FindDuplicatesAsync(
        Guid tenantId, string? firstName, string? lastName, DateOnly? dateOfBirth, string? phone, Guid? excludePatientId,
        string? email, string? abha, CancellationToken ct)
    {
        var first = firstName?.Trim();
        var last = lastName?.Trim();
        var names = !string.IsNullOrEmpty(first) && !string.IsNullOrEmpty(last);
        var normalized = PatientPhone.Normalize(phone);
        var emailNorm = string.IsNullOrWhiteSpace(email) ? null : email.Trim().ToLowerInvariant();
        var abhaDigits = Digits(abha);
        var rows = await db.Patients.AsNoTracking().Where(p => p.TenantId == tenantId && p.Id != excludePatientId).ToListAsync(ct);
        var ids = rows.Select(p => p.Id).ToHashSet();
        var phoneRows = await db.PatientPhones.AsNoTracking().Where(p => !p.IsDeleted).ToListAsync(ct);
        var phonesByPatient = phoneRows.Where(p => ids.Contains(p.PatientId)).GroupBy(p => p.PatientId)
            .ToDictionary(g => g.Key, g => g.Select(p => PatientPhone.Normalize(p.PhoneE164)).OfType<string>().ToHashSet(StringComparer.Ordinal));
        return rows
            .Select(p =>
            {
                var reasons = new List<string>();
                var nameMatch = names
                    && string.Equals(p.FirstName.Trim(), first, StringComparison.OrdinalIgnoreCase)
                    && string.Equals(p.LastName.Trim(), last, StringComparison.OrdinalIgnoreCase);
                if (nameMatch && dateOfBirth is not null && p.DateOfBirth == dateOfBirth)
                {
                    reasons.Add("name_dob");
                }
                else if (nameMatch && (dateOfBirth is null || p.DateOfBirth is null))
                {
                    reasons.Add("name");
                }

                if (!phonesByPatient.TryGetValue(p.Id, out var numbers))
                {
                    numbers = new HashSet<string>(StringComparer.Ordinal);
                }

                if (PatientPhone.Normalize(p.Phone) is { } mirror)
                {
                    numbers.Add(mirror);
                }

                if (normalized is not null && numbers.Contains(normalized))
                {
                    reasons.Add("phone");
                }

                if (emailNorm is not null && !string.IsNullOrWhiteSpace(p.Email)
                    && string.Equals(p.Email.Trim(), emailNorm, StringComparison.OrdinalIgnoreCase))
                {
                    reasons.Add("email");
                }

                var rowAbha = Digits(p.AbhaNumber);
                if (abhaDigits is { Length: 14 } && rowAbha is { Length: 14 } && abhaDigits == rowAbha)
                {
                    reasons.Add("abha");
                }

                return new DuplicateCandidateDto(p.Id, p.Mrn, p.FirstName, p.LastName, p.DateOfBirth, p.Phone, p.RegisteredBranchId, reasons);
            })
            .Where(c => c.MatchReasons.Count > 0)
            .OrderByDescending(c => c.MatchReasons.Any(r => r is "email" or "phone" or "abha"))
            .ThenByDescending(c => c.MatchReasons.Count).ThenBy(c => c.LastName).ThenBy(c => c.FirstName).ThenBy(c => c.Mrn)
            .Take(20)
            .ToList();
    }

    private static string? Digits(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var digits = new string(value.Where(char.IsDigit).ToArray());
        return digits.Length == 0 ? null : digits;
    }

    public async Task SoftDeleteAsync(Guid patientId, string? reason, CancellationToken ct)
    {
        var patient = await db.Patients.SingleOrDefaultAsync(p => p.Id == patientId, ct) ?? throw new FakeDbException("P0002");
        if (!tenant.Can(HmsPermissions.PatientsDelete))
        {
            throw new FakeDbException("42501");
        }

        patient.DeletedAt = clock.GetUtcNow();
        patient.IsDeleted = true; // generated from deleted_at in PostgreSQL
        await db.SaveChangesAsync(ct);
    }

    public async Task RestoreAsync(Guid patientId, CancellationToken ct)
    {
        var patient = await db.Patients.IgnoreQueryFilters()
            .SingleOrDefaultAsync(p => p.Id == patientId && p.TenantId == tenant.TenantId && p.DeletedAt != null, ct)
            ?? throw new FakeDbException("P0002");
        if (patient.MergedIntoPatientId is not null)
        {
            throw new FakeDbException("55000", "merged patient cannot be restored");
        }

        patient.DeletedAt = null;
        patient.IsDeleted = false;
        await db.SaveChangesAsync(ct);
    }

    public async Task MergeAsync(Guid survivorId, Guid duplicateId, string reason, CancellationToken ct)
    {
        if (!tenant.Can(HmsPermissions.PatientsRestore))
        {
            throw new FakeDbException("42501");
        }

        var trimmed = reason?.Trim();
        if (string.IsNullOrEmpty(trimmed))
        {
            throw new FakeDbException("22023", "reason is required");
        }

        if (trimmed.Length > 500)
        {
            throw new FakeDbException("22023", "reason too long (max 500)");
        }

        if (survivorId == duplicateId)
        {
            throw new FakeDbException("22023", "a chart cannot be merged into itself");
        }

        var rows = await db.Patients.IgnoreQueryFilters()
            .Where(p => p.Id == survivorId || p.Id == duplicateId)
            .ToListAsync(ct);
        var survivor = rows.SingleOrDefault(p => p.Id == survivorId);
        var duplicate = rows.SingleOrDefault(p => p.Id == duplicateId);
        if (survivor is null || duplicate is null || survivor.TenantId != tenant.TenantId || duplicate.TenantId != survivor.TenantId)
        {
            throw new FakeDbException("P0002");
        }

        if (duplicate.MergedIntoPatientId == survivor.Id && duplicate.DeletedAt is not null)
        {
            return;
        }

        if (duplicate.MergedIntoPatientId is not null)
        {
            throw new FakeDbException("22023", "patient is already merged into another chart");
        }

        if (survivor.DeletedAt is not null || survivor.MergedIntoPatientId is not null)
        {
            throw new FakeDbException("22023", "survivor is not a live chart");
        }

        var phones = await db.PatientPhones.Where(p => p.PatientId == duplicate.Id).ToListAsync(ct);
        var survivorPhones = await db.PatientPhones.Where(p => p.PatientId == survivor.Id).ToListAsync(ct);
        var survivorNumbers = survivorPhones.Select(p => PatientPhone.Normalize(p.PhoneE164)).OfType<string>().ToHashSet(StringComparer.Ordinal);
        var hasPrimary = survivorPhones.Any(p => p.IsPrimary);
        var hasWhatsapp = survivorPhones.Any(p => p.IsWhatsapp);
        foreach (var phone in phones)
        {
            var normalized = PatientPhone.Normalize(phone.PhoneE164);
            if (normalized is not null && survivorNumbers.Contains(normalized))
            {
                phone.IsDeleted = true;
                continue;
            }

            var primary = phone.IsPrimary && !hasPrimary;
            var whatsapp = phone.IsWhatsapp && !hasWhatsapp;
            if (!primary && !whatsapp)
            {
                phone.IsDeleted = true;
                continue;
            }

            phone.PatientId = survivor.Id;
            phone.IsPrimary = primary;
            phone.IsWhatsapp = whatsapp;
            if (primary)
            {
                hasPrimary = true;
            }

            if (whatsapp)
            {
                hasWhatsapp = true;
            }

            if (normalized is not null)
            {
                survivorNumbers.Add(normalized);
            }
        }

        if (string.IsNullOrWhiteSpace(survivor.Email))
        {
            survivor.Email = string.IsNullOrWhiteSpace(duplicate.Email) ? null : duplicate.Email.Trim();
        }

        survivor.AbhaNumber ??= duplicate.AbhaNumber;
        survivor.DateOfBirth ??= duplicate.DateOfBirth;
        if (survivor.Sex == PatientSex.Unknown && duplicate.Sex != PatientSex.Unknown)
        {
            survivor.Sex = duplicate.Sex;
        }

        if (string.IsNullOrWhiteSpace(survivor.Phone))
        {
            survivor.Phone = survivorPhones.Concat(phones).FirstOrDefault(p => p.PatientId == survivor.Id && p.IsPrimary && !p.IsDeleted)?.PhoneE164;
        }

        var now = clock.GetUtcNow();
        duplicate.DeletedAt = now;
        duplicate.IsDeleted = true;
        duplicate.MergedIntoPatientId = survivor.Id;
        duplicate.MergedAt = now;
        duplicate.MergedBy = tenant.UserId;
        await db.SaveChangesAsync(ct);
    }

    internal static readonly System.Collections.Concurrent.ConcurrentDictionary<Guid, Hms.Modules.Patients.Endpoints.RegistrationSettings> Settings = new();

    public Task<Hms.Modules.Patients.Endpoints.RegistrationSettings> RegistrationSettingsAsync(Guid tenantId, CancellationToken ct) =>
        Task.FromResult(Settings.TryGetValue(tenantId, out var s) ? s : Hms.Modules.Patients.Endpoints.RegistrationSettings.Defaults);

    public Task SaveRegistrationSettingsAsync(Guid tenantId, Hms.Modules.Patients.Endpoints.RegistrationSettings settings, CancellationToken ct)
    {
        Settings[tenantId] = settings;
        return Task.CompletedTask;
    }

    public Task<string?> DefaultCountryCodeAsync(Guid tenantId, CancellationToken ct) =>
        Task.FromResult<string?>(tenantId == tenant.TenantId ? "+91" : null);

    /// <summary>Bookings the in-process tests register (patient id → booking time); tenant-checked like the SQL.</summary>
    public static System.Collections.Concurrent.ConcurrentBag<(Guid TenantId, Guid PatientId, DateTimeOffset At)> Bookings { get; } = [];

    public Task<IReadOnlyList<(Guid PatientId, DateTimeOffset LastBookedAt)>> LastBookedAsync(Guid tenantId, int limit, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<(Guid, DateTimeOffset)>>(tenantId != tenant.TenantId ? [] :
            [.. Bookings.Where(b => b.TenantId == tenantId).GroupBy(b => b.PatientId)
                .Select(g => (g.Key, g.Max(b => b.At))).OrderByDescending(x => x.Item2).ThenBy(x => x.Key).Take(Math.Clamp(limit, 1, 500))]);

    /// <summary>Mirrors patient.set_patient_phones: desired state, changed rows replaced (soft delete), mirror kept.</summary>
    public async Task SetPhonesAsync(Guid patientId, string? phone, bool whatsappSameAsPhone, string? whatsapp, CancellationToken ct)
    {
        var patient = await db.Patients.SingleOrDefaultAsync(p => p.Id == patientId, ct) ?? throw new FakeDbException("P0002");
        if (!tenant.Can(HmsPermissions.PatientsEdit))
        {
            throw new FakeDbException("42501");
        }

        if ((phone is not null && !PhoneE164.IsE164(phone)) || (whatsapp is not null && !PhoneE164.IsE164(whatsapp)) || (whatsappSameAsPhone && phone is null))
        {
            throw new FakeDbException("22023");
        }

        var wa = whatsappSameAsPhone ? phone : whatsapp;
        var wanted = new[] { phone, wa }.Select(PatientPhone.Normalize).OfType<string>().ToHashSet(StringComparer.Ordinal);
        if (wanted.Count > 0)
        {
            var others = await db.Patients.AsNoTracking().Where(p => p.TenantId == patient.TenantId && p.Id != patientId).Select(p => p.Phone).ToListAsync(ct);
            var otherPhones = await db.PatientPhones.AsNoTracking().Where(p => p.PatientId != patientId && !p.IsDeleted).Select(p => p.PhoneE164).ToListAsync(ct);
            if (others.Concat(otherPhones).Select(PatientPhone.Normalize).Any(n => n is not null && wanted.Contains(n)))
            {
                throw new FakeDbException("23505", "duplicate_phone: another patient in this hospital already has this phone number");
            }
        }

        var live = await db.PatientPhones.Where(p => p.PatientId == patientId).ToListAsync(ct);
        foreach (var row in live.Where(r => r.IsPrimary != (r.PhoneE164 == phone) || r.IsWhatsapp != (r.PhoneE164 == wa)))
        {
            row.IsDeleted = true;
        }

        var kept = live.Where(r => !r.IsDeleted).Select(r => r.PhoneE164).ToHashSet(StringComparer.Ordinal);
        if (phone is not null && !kept.Contains(phone))
        {
            db.PatientPhones.Add(new PatientPhoneNumber { PatientId = patientId, PhoneE164 = phone, IsPrimary = true, IsWhatsapp = phone == wa });
        }

        if (wa is not null && wa != phone && !kept.Contains(wa))
        {
            db.PatientPhones.Add(new PatientPhoneNumber { PatientId = patientId, PhoneE164 = wa, IsWhatsapp = true });
        }

        patient.Phone = phone;
        await db.SaveChangesAsync(ct);
    }
}

/// <summary>Unit-test stand-in for the patient.assign_mrn() trigger: per-tenant counter, CODE-000001.</summary>
internal sealed class FakeMrnTrigger : Microsoft.EntityFrameworkCore.Diagnostics.SaveChangesInterceptor
{
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<Guid, long> Counters = new();

    public override ValueTask<Microsoft.EntityFrameworkCore.Diagnostics.InterceptionResult<int>> SavingChangesAsync(
        Microsoft.EntityFrameworkCore.Diagnostics.DbContextEventData eventData,
        Microsoft.EntityFrameworkCore.Diagnostics.InterceptionResult<int> result,
        CancellationToken cancellationToken = default)
    {
        foreach (var entry in eventData.Context!.ChangeTracker.Entries<Hms.Modules.Patients.Domain.Patient>())
        {
            if (entry.State == EntityState.Added)
            {
                var n = Counters.AddOrUpdate(entry.Entity.TenantId, 1, (_, v) => v + 1);
                entry.Entity.Mrn = $"TEST-{n:D6}";
            }
        }

        return base.SavingChangesAsync(eventData, result, cancellationToken);
    }
}

internal sealed class FakeDbException(string sqlState, string message = "fake") : System.Data.Common.DbException(message)
{
    public override string SqlState { get; } = sqlState;
}
