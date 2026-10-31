#!/usr/bin/env python3
"""Zero-downtime credential rotation helper (issue #68).

Blue/green DB logins: every service has two login roles, slot a = hms_<svc>_login and
slot b = hms_<svc>_login_b. Both are NOINHERIT members of hms_svc_<svc> (the app runs
SET ROLE hms_svc_<svc>), so either can serve the app. A rotation gives the idle slot a
fresh password, points the app at it through the normal deploy, and only then disables
the old slot. The old login keeps working until retire, so a failed deploy that restores
the previous app secret can never strand the app (the 2026-10-31 incident).

Edge key: services accept Edge:Key and Edge:PreviousKey; the edge sends Edge:Key.

Nothing here talks to Postgres. SQL is written to a 0600 file for an operator to run
(Supabase SQL editor or MCP); it contains only a SCRAM verifier, never a password.
Passwords and connection strings go from memory to `gh secret set` on stdin, or to 0600
files under ROTATION_DIR (default /dev/shm/hms-rotation). Output is names, slots and
short sha256 prefixes only. See docs/runbooks/credential-rotation.md.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import os
import re
import secrets
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = Path(os.environ.get("ACA_SECRETS_MANIFEST", ROOT / ".github" / "aca-secrets.tsv"))
SCRAM_ITERATIONS = int(os.environ.get("ROTATION_SCRAM_ITERATIONS", "4096"))
PASSWORD_BYTES = int(os.environ.get("ROTATION_PASSWORD_BYTES", "32"))
SLOT_B_SUFFIX = "_b"
ROLE_RE = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")


class RotationError(Exception):
    pass


def env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if not value:
        raise RotationError(f"set {name}")
    return value


def short_hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()[:12]


# --- manifest -------------------------------------------------------------------------
def manifest_rows() -> list[list[str]]:
    rows = []
    for line in MANIFEST.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) != 5:
            raise RotationError(f"bad manifest line: {cols[:2]}")
        rows.append(cols)
    return rows


def db_secret(service: str) -> tuple[str, str]:
    """(container app secret name, GitHub secret name) of a service's DB connection."""
    for svc, aca, gh, env_name, _ in manifest_rows():
        if svc == service and env_name == "ConnectionStrings__HmsDatabase":
            return aca, gh
    raise RotationError(f"{service} has no DB connection row in {MANIFEST.name}")


def edge_key_secrets() -> tuple[str, str, str, str]:
    """(aca current, gh current, aca previous, gh previous) for the edge key."""
    cur = prev = None
    for _, aca, gh, env_name, _ in manifest_rows():
        if env_name == "Edge__Key":
            cur = (aca, gh)
        elif env_name == "Edge__PreviousKey":
            prev = (aca, gh)
    if not cur or not prev:
        raise RotationError("manifest needs Edge__Key and Edge__PreviousKey rows")
    return cur[0], cur[1], prev[0], prev[1]


# --- connection strings and slots -----------------------------------------------------
def parse_connstr(value: str) -> list[tuple[str, str]]:
    pairs = []
    for part in value.strip().split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            pairs.append((k.strip(), v))
    return pairs


def connstr_get(pairs: list[tuple[str, str]], key: str) -> str:
    for k, v in pairs:
        if k.lower() == key.lower():
            return v
    raise RotationError(f"connection string has no {key}")


def connstr_with(pairs: list[tuple[str, str]], **updates: str) -> str:
    lowered = {k.lower(): v for k, v in updates.items()}
    seen = set()
    out = []
    for k, v in pairs:
        if k.lower() in lowered:
            v = lowered[k.lower()]
            seen.add(k.lower())
        out.append(f"{k}={v}")
    missing = set(lowered) - seen
    if missing:
        raise RotationError(f"connection string has no {sorted(missing)}")
    return ";".join(out)


def split_user(user: str) -> tuple[str, str]:
    """Supabase pooler users look like role.projectref; direct users are just role."""
    role, dot, tenant = user.partition(".")
    if not ROLE_RE.match(role):
        raise RotationError("unexpected role name in connection string")
    return role, (dot + tenant)


def slots(role: str) -> tuple[str, str]:
    """(slot a, slot b) for either slot's role name."""
    base = role[: -len(SLOT_B_SUFFIX)] if role.endswith(SLOT_B_SUFFIX) else role
    return base, base + SLOT_B_SUFFIX


def standby_of(role: str) -> str:
    a, b = slots(role)
    return a if role == b else b


def group_role(role: str) -> str:
    """hms_<svc>_login(_b) -> hms_svc_<svc>."""
    a, _ = slots(role)
    m = re.fullmatch(r"hms_([a-z0-9]+)_login", a)
    if not m:
        raise RotationError("login role must be named hms_<service>_login")
    return f"hms_svc_{m.group(1)}"


# --- SCRAM ----------------------------------------------------------------------------
def scram_verifier(password: str, salt: bytes | None = None, iterations: int = SCRAM_ITERATIONS) -> str:
    salt = salt or secrets.token_bytes(16)
    salted = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    client_key = hmac.new(salted, b"Client Key", "sha256").digest()
    server_key = hmac.new(salted, b"Server Key", "sha256").digest()
    b64 = lambda b: base64.b64encode(b).decode()
    return f"SCRAM-SHA-256${iterations}:{b64(salt)}${b64(hashlib.sha256(client_key).digest())}:{b64(server_key)}"


def new_password() -> str:
    return secrets.token_urlsafe(PASSWORD_BYTES)


# --- SQL ------------------------------------------------------------------------------
def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def prepare_sql(active: str, standby: str, verifier: str) -> str:
    """Create or refresh the standby login as a copy of the active one, with a new verifier."""
    for r in (active, standby):
        if not ROLE_RE.match(r):
            raise RotationError("bad role name")
    group = group_role(active)
    return f"""-- #68 rotation: prepare {standby} (copy of {active}). Contains a SCRAM verifier only.
begin;
do $rot$
declare src pg_roles%rowtype; cfg text;
begin
  select * into src from pg_roles where rolname = {sql_literal(active)};
  if not found then raise exception 'active login % is missing', {sql_literal(active)}; end if;
  if not exists (select 1 from pg_roles where rolname = {sql_literal(standby)}) then
    execute format('create role %I noinherit nologin', {sql_literal(standby)});
  end if;
  execute format('alter role %I noinherit connection limit %s', {sql_literal(standby)}, src.rolconnlimit);
  execute format('alter role %I reset all', {sql_literal(standby)});
  foreach cfg in array coalesce(src.rolconfig, '{{}}') loop
    execute format('alter role %I set %s to %L', {sql_literal(standby)}, split_part(cfg, '=', 1), substr(cfg, strpos(cfg, '=') + 1));
  end loop;
  execute format('grant %I to %I', {sql_literal(group)}, {sql_literal(standby)});
  execute format('alter role %I login password %L', {sql_literal(standby)}, {sql_literal(verifier)});
end
$rot$;
commit;
"""


def retire_sql(old: str) -> str:
    if not ROLE_RE.match(old):
        raise RotationError("bad role name")
    return f"""-- #68 rotation: retire {old}. The app no longer uses it.
alter role {old} nologin password null;
"""


def rollback_sql(role: str, verifier: str) -> str:
    return f"-- #68 rotation: re-enable {role} with its previous password (verifier only)\nalter role {role} login password {sql_literal(verifier)};\n"


# --- side effects (az / gh / files) ---------------------------------------------------
def run(cmd: list[str], stdin: str | None = None) -> str:
    res = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    if res.returncode != 0:
        raise RotationError(f"{' '.join(cmd[:3])} failed (exit {res.returncode})")
    return res.stdout


def live_secret(app: str, secret: str) -> str:
    rg = env("RG")
    return run(["az", "containerapp", "secret", "show", "-g", rg, "-n", app, "--secret-name", secret,
                "--query", "value", "-o", "tsv"]).strip()


def app_name(service: str) -> str:
    return env("ROTATION_APP_PREFIX", "ca-hms-") + service


def gh_secret_set(name: str, value: str) -> None:
    run(["gh", "secret", "set", name], stdin=value)


def workdir() -> Path:
    d = Path(os.environ.get("ROTATION_DIR", "/dev/shm/hms-rotation"))
    d.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    return d


def write_private(path: Path, value: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(value)


# --- commands -------------------------------------------------------------------------
def cmd_status(service: str) -> None:
    aca, gh = db_secret(service)
    value = live_secret(app_name(service), aca)
    role, _ = split_user(connstr_get(parse_connstr(value), "Username"))
    a, b = slots(role)
    print(f"{service}: app uses {role} (slot {'b' if role == b else 'a'}), standby {standby_of(role)}, "
          f"{aca} sha256 {short_hash(value)}, GitHub secret {gh}")


def cmd_prepare(service: str) -> None:
    aca, gh = db_secret(service)
    live = live_secret(app_name(service), aca)
    pairs = parse_connstr(live)
    role, tenant = split_user(connstr_get(pairs, "Username"))
    standby = standby_of(role)
    password = new_password()
    new = connstr_with(pairs, Username=standby + tenant, Password=password)
    d = workdir()
    write_private(d / f"{service}.connstr", new)
    write_private(d / f"{service}.prepare.sql", prepare_sql(role, standby, scram_verifier(password)))
    write_private(d / f"{service}.active", role)
    print(f"{service}: prepared {standby} (active {role}); new connstr sha256 {short_hash(new)}; "
          f"run {d / (service + '.prepare.sql')} in Supabase, then: publish {service}")


def cmd_publish(service: str) -> None:
    _, gh = db_secret(service)
    path = workdir() / f"{service}.connstr"
    if not path.exists():
        raise RotationError(f"run prepare {service} first")
    value = path.read_text()
    gh_secret_set(gh, value)
    print(f"{service}: {gh} set (sha256 {short_hash(value)}). Dispatch deploy-aca with the current tag and a blank service.")


def cmd_retire(service: str) -> None:
    aca, _ = db_secret(service)
    d = workdir()
    marker = d / f"{service}.active"
    if not marker.exists():
        raise RotationError(f"no prepared rotation for {service}")
    old = marker.read_text().strip()
    live_role, _ = split_user(connstr_get(parse_connstr(live_secret(app_name(service), aca)), "Username"))
    if live_role == old:
        raise RotationError(f"{service} app still uses {old}; deploy and verify before retiring it")
    if live_role != standby_of(old):
        raise RotationError(f"{service} app uses {live_role}, expected {standby_of(old)}")
    write_private(d / f"{service}.retire.sql", retire_sql(old))
    print(f"{service}: app uses {live_role}; run {d / (service + '.retire.sql')} to disable {old}")


def cmd_edge_prepare() -> None:
    aca_cur, gh_cur, _, gh_prev = edge_key_secrets()
    current = live_secret(app_name("edge"), aca_cur)
    new = new_password()
    gh_secret_set(gh_prev, current)
    gh_secret_set(gh_cur, new)
    print(f"edge key: {gh_prev} = live key (sha256 {short_hash(current)}), {gh_cur} = new key "
          f"(sha256 {short_hash(new)}). Dispatch deploy-aca with the current tag and a blank service (edge rolls last).")


def cmd_edge_retire() -> None:
    aca_cur, gh_cur, _, gh_prev = edge_key_secrets()
    current = live_secret(app_name("edge"), aca_cur)
    gh_secret_set(gh_prev, current)
    print(f"edge key: {gh_prev} = current key (sha256 {short_hash(current)}); previous key retired after the next full deploy.")


def cmd_cleanup() -> None:
    d = workdir()
    for f in d.iterdir():
        f.write_bytes(b"\0" * f.stat().st_size)
        f.unlink()
    d.rmdir()
    print("rotation files removed")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("status", "prepare", "publish", "retire"):
        sub.add_parser(name).add_argument("service")
    for name in ("edge-prepare", "edge-retire", "cleanup"):
        sub.add_parser(name)
    a = p.parse_args(argv)
    try:
        if a.cmd in ("status", "prepare", "publish", "retire"):
            {"status": cmd_status, "prepare": cmd_prepare, "publish": cmd_publish, "retire": cmd_retire}[a.cmd](a.service)
        else:
            {"edge-prepare": cmd_edge_prepare, "edge-retire": cmd_edge_retire, "cleanup": cmd_cleanup}[a.cmd]()
    except RotationError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
