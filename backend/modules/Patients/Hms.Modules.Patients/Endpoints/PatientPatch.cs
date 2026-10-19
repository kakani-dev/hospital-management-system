using System.Globalization;
using System.Text.Json;

namespace Hms.Modules.Patients.Endpoints;

/// <summary>
/// PATCH /patients/{id} body with JSON merge-patch semantics: an ABSENT property is unchanged, an
/// explicit null clears a nullable field. Parsed from the raw JSON so "absent" and "null" differ.
/// </summary>
public sealed class PatientPatch
{
    private static readonly HashSet<string> Known = new(StringComparer.OrdinalIgnoreCase)
    {
        "firstName", "lastName", "dateOfBirth", "sex", "phone", "email", "registeredBranchId", "mrn", "whatsapp",
    };

    // Accepted and ignored everywhere in the API: the tenant always comes from the server context.
    private static readonly HashSet<string> Ignored = new(StringComparer.OrdinalIgnoreCase) { "tenantId" };

    public Field<string?> FirstName { get; private set; }
    public Field<string?> LastName { get; private set; }
    public Field<DateOnly?> DateOfBirth { get; private set; }
    public Field<string?> Sex { get; private set; }
    public Field<string?> Phone { get; private set; }
    public Field<string?> Email { get; private set; }
    public Field<Guid?> RegisteredBranchId { get; private set; }
    public Field<string?> Mrn { get; private set; }

    /// <summary>Absent = unchanged; null = no WhatsApp; object = { sameAsPhone, number }.</summary>
    public Field<WhatsappInput?> Whatsapp { get; private set; }

    public static PatientPatch Parse(JsonElement body, Dictionary<string, string[]> errors)
    {
        var patch = new PatientPatch();
        if (body.ValueKind != JsonValueKind.Object)
        {
            errors["body"] = ["The request body must be a JSON object."];
            return patch;
        }

        foreach (var property in body.EnumerateObject())
        {
            var name = property.Name;
            if (Ignored.Contains(name))
            {
                continue;
            }

            if (!Known.Contains(name))
            {
                errors[name] = ["Unknown or read-only property."];
                continue;
            }

            var value = property.Value;
            switch (name.ToUpperInvariant())
            {
                case "FIRSTNAME": patch.FirstName = Text(value, "firstName", errors); break;
                case "LASTNAME": patch.LastName = Text(value, "lastName", errors); break;
                case "SEX": patch.Sex = Text(value, "sex", errors); break;
                case "PHONE": patch.Phone = Text(value, "phone", errors); break;
                case "EMAIL": patch.Email = Text(value, "email", errors); break;
                case "MRN": patch.Mrn = Text(value, "mrn", errors); break;
                case "WHATSAPP": patch.Whatsapp = WhatsappValue(value, errors); break;
                case "DATEOFBIRTH": patch.DateOfBirth = Date(value, errors); break;
                case "REGISTEREDBRANCHID": patch.RegisteredBranchId = BranchId(value, errors); break;
            }
        }

        return patch;
    }

    private static Field<string?> Text(JsonElement value, string field, Dictionary<string, string[]> errors)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Null: return new Field<string?>(true, null);
            case JsonValueKind.String: return new Field<string?>(true, value.GetString());
            default:
                errors[field] = ["Must be a string or null."];
                return default;
        }
    }

    private static Field<WhatsappInput?> WhatsappValue(JsonElement value, Dictionary<string, string[]> errors)
    {
        if (value.ValueKind == JsonValueKind.Null)
        {
            return new Field<WhatsappInput?>(true, null);
        }

        if (value.ValueKind == JsonValueKind.Object)
        {
            bool? same = null;
            string? number = null;
            foreach (var p in value.EnumerateObject())
            {
                if (p.NameEquals("sameAsPhone") && p.Value.ValueKind is JsonValueKind.True or JsonValueKind.False)
                {
                    same = p.Value.GetBoolean();
                }
                else if (p.NameEquals("number") && p.Value.ValueKind is JsonValueKind.String or JsonValueKind.Null)
                {
                    number = p.Value.ValueKind == JsonValueKind.String ? p.Value.GetString() : null;
                }
                else
                {
                    errors["whatsapp"] = ["Must be { sameAsPhone: boolean, number?: string } or null."];
                    return default;
                }
            }

            return new Field<WhatsappInput?>(true, new WhatsappInput(same, number));
        }

        errors["whatsapp"] = ["Must be { sameAsPhone: boolean, number?: string } or null."];
        return default;
    }

    private static Field<DateOnly?> Date(JsonElement value, Dictionary<string, string[]> errors)
    {
        if (value.ValueKind == JsonValueKind.Null)
        {
            return new Field<DateOnly?>(true, null);
        }

        if (value.ValueKind == JsonValueKind.String
            && DateOnly.TryParseExact(value.GetString(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
        {
            return new Field<DateOnly?>(true, date);
        }

        errors["dateOfBirth"] = ["Must be a date (YYYY-MM-DD) or null."];
        return default;
    }

    private static Field<Guid?> BranchId(JsonElement value, Dictionary<string, string[]> errors)
    {
        if (value.ValueKind == JsonValueKind.String && Guid.TryParse(value.GetString(), out var id) && id != Guid.Empty)
        {
            return new Field<Guid?>(true, id);
        }

        errors["registeredBranchId"] = ["Must be a branch id (it cannot be null)."];
        return default;
    }

    public readonly record struct Field<T>(bool IsSet, T Value)
    {
        public T Or(T current) => IsSet ? Value : current;
    }
}
