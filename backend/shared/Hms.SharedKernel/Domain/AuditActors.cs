namespace Hms.SharedKernel.Domain;

// Self-contained (BCL only, no project dependencies) so the microservices work can move it
// into Hms.Platform as-is; only the namespace changes.

/// <summary>Well-known audit actors (created_by / updated_by values that are not signed-in users).</summary>
public static class AuditActors
{
    /// <summary>
    /// "MediCore System": audit.system_actor() in the database (migration 20261012090000). Used for
    /// back-filled rows and writes without a signed-in user (jobs, the outbox dispatcher, seeds).
    /// It has no auth.users row, which is why created_by/updated_by carry no foreign key.
    /// </summary>
    public static readonly Guid System = Guid.Parse("00000000-0000-4000-8000-00000000005e");
}
