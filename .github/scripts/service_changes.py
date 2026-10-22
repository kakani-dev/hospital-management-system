#!/usr/bin/env python3
"""Which container images a commit needs to build and deploy.

Path rules (deploy order is always identity, patients, scheduling, then edge):

- backend/platform, backend/shared, Directory.Build.props, Directory.Packages.props,
  global.json, or .dockerignore change every image.
- Each service image otherwise changes only with its own host and module.
- .github/workflows/deploy-aca.yml also selects the edge. The running edge revision
  can be older than main (it was still sha-eb314ae when this pipeline was enabled)
  even when backend/edge itself did not change.
- The legacy gateway, the Vercel app, and SQL migrations do not select an image.
  This pipeline never deploys medicore-hms-api.

Image tags are sha- plus the full 40-character commit sha, matching the tags
already running in ACR (acrmedicorehmsdev.azurecr.io/hms-<svc>:sha-<40 hex>).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ORDER = ("identity", "patients", "scheduling", "edge")

DOCKERFILES = {
    "identity": "backend/services/identity/Dockerfile",
    "patients": "backend/services/patients/Dockerfile",
    "scheduling": "backend/services/scheduling/Dockerfile",
    "edge": "backend/edge/Dockerfile",
}

SHARED_PREFIXES = ("backend/platform/", "backend/shared/")
SHARED_FILES = {
    "backend/Directory.Build.props",
    "backend/Directory.Packages.props",
    "backend/global.json",
    ".dockerignore",
}
SERVICE_PREFIXES = {
    "identity": ("backend/services/identity/", "backend/modules/Identity/"),
    "patients": ("backend/services/patients/", "backend/modules/Patients/"),
    "scheduling": ("backend/services/scheduling/", "backend/modules/Appointments/"),
    "edge": ("backend/edge/",),
}
# Enabling or changing the deploy workflow publishes the edge. Path filters on the
# enabling commit would otherwise skip it, and ca-hms-edge was still on sha-eb314ae.
EDGE_ALSO = {".github/workflows/deploy-aca.yml"}

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
TAG_RE = re.compile(r"^sha-[0-9a-f]{7,40}$")
SHORT_LEN = 12  # only used when a suffix would make the revision name longer than 64
# Container Apps revision names are "{app}--{suffix}" and must be at most 64 characters.
MAX_REVISION_NAME = 64


def norm(path: str) -> str:
    path = path.strip().replace("\\", "/")
    while path.startswith("./"):
        path = path[2:]
    return path


def services_for_paths(paths: list[str]) -> list[str]:
    """Return deploy-ordered service names touched by these paths."""
    normalized = [norm(p) for p in paths if norm(p)]
    if any(p in SHARED_FILES or p.startswith(SHARED_PREFIXES) for p in normalized):
        return list(ORDER)
    chosen = [
        service
        for service in ORDER
        if any(p.startswith(SERVICE_PREFIXES[service]) for p in normalized)
    ]
    if any(p in EDGE_ALSO for p in normalized) and "edge" not in chosen:
        chosen.append("edge")
    return [service for service in ORDER if service in chosen]


def image_tag(sha: str) -> str:
    """Tag pushed to ACR. Production apps run sha- plus the full 40-character commit sha."""
    if not SHA_RE.fullmatch(sha):
        raise SystemExit(f"sha must be 40 hex characters, got {sha!r}")
    return "sha-" + sha


def revision_suffix(app: str, tag: str) -> str:
    """Suffix that keeps '{app}--{suffix}' within the Container Apps name limit.

    The suffix starts with a letter (Azure rejects a leading digit).
    """
    if not TAG_RE.fullmatch(tag):
        raise SystemExit(f"image tag must look like sha-<hex>, got {tag!r}")
    suffix = tag
    if len(app) + 2 + len(suffix) > MAX_REVISION_NAME:
        suffix = "sha-" + tag.split("-", 1)[1][:SHORT_LEN]
    if len(app) + 2 + len(suffix) > MAX_REVISION_NAME:
        raise SystemExit(f"revision name for {app} and {tag} is still too long")
    if not re.fullmatch(r"[a-z][a-z0-9-]*[a-z0-9]", suffix):
        raise SystemExit(f"revision suffix {suffix!r} is not a valid Container Apps suffix")
    return suffix


def order(names: list[str]) -> list[str]:
    unknown = [name for name in names if name not in ORDER]
    if unknown:
        raise SystemExit(f"unknown service(s): {', '.join(unknown)}. Choose from {', '.join(ORDER)}.")
    return [name for name in ORDER if name in names]


def matrix(services: list[str]) -> str:
    include = [{"service": service, "dockerfile": DOCKERFILES[service]} for service in services]
    return json.dumps({"include": include}, separators=(",", ":"))


def plan(sha: str, service: str, tag: str, paths: list[str]) -> dict[str, str]:
    if not SHA_RE.fullmatch(sha):
        raise SystemExit(f"sha must be 40 hex characters, got {sha!r}")
    service = service.strip()
    tag = tag.strip()
    if service and service not in ORDER:
        raise SystemExit(f"unknown service {service!r}. Choose one of {', '.join(ORDER)}, or leave it blank.")
    if tag and not TAG_RE.fullmatch(tag):
        raise SystemExit(f"tag must look like sha-<7-40 hex>, got {tag!r}")

    # Emergency hatch: an explicit tag is rolled onto one service or onto all four. Nothing is built.
    if tag:
        services = [service] if service else list(ORDER)
        build = False
    elif service:
        services = [service]
        build = True
        tag = image_tag(sha)
    else:
        services = services_for_paths(paths)
        build = bool(services)
        tag = image_tag(sha)

    return {
        "sha": sha,
        "tag": tag,
        "build": "true" if build else "false",
        "deploy": "true" if services else "false",
        "services": ",".join(services),
        "matrix": matrix(services if build else []),
    }


def emit(result: dict[str, str]) -> None:
    for key in ("sha", "tag", "build", "deploy", "services", "matrix"):
        print(f"{key}={result[key]}")


def self_test() -> None:
    assert services_for_paths(["apps/web/src/App.tsx", "backend/gateway/Program.cs"]) == []
    assert services_for_paths(["supabase/migrations/20261013090100_x.sql"]) == []
    assert services_for_paths(["backend/services/patients/Dockerfile"]) == ["patients"]
    assert services_for_paths([".github/workflows/deploy-aca.yml"]) == ["edge"]
    assert services_for_paths(
        ["backend/modules/Identity/Endpoints/Me.cs", ".github/workflows/deploy-aca.yml"]
    ) == ["identity", "edge"]
    assert services_for_paths([".github/workflows/ci.yml", "docs/deploy.md"]) == []
    assert services_for_paths(["./backend/services/patients/Dockerfile"]) == ["patients"]
    assert services_for_paths(["backend/modules/Identity/Endpoints/Me.cs"]) == ["identity"]
    assert services_for_paths(["backend/modules/Appointments/Scheduling/Book.cs"]) == ["scheduling"]
    assert services_for_paths(["backend/edge/Hms.Edge/EdgeHost.cs"]) == ["edge"]
    assert services_for_paths(
        ["backend/edge/Dockerfile", "backend/services/identity/Hms.Identity.Api/Program.cs"]
    ) == ["identity", "edge"]
    assert services_for_paths(["backend/platform/Health/HealthCheckSetup.cs"]) == list(ORDER)
    assert services_for_paths(["backend/shared/Hms.SharedKernel/Domain/AuditActors.cs"]) == list(ORDER)
    assert services_for_paths(["backend/Directory.Packages.props"]) == list(ORDER)
    assert services_for_paths([".dockerignore"]) == list(ORDER)
    assert services_for_paths(["backend/platform/X.cs", "backend/modules/Patients/Y.cs"]) == list(ORDER)

    sha = "0123456789abcdef" * 2 + "01234567"
    assert len(sha) == 40
    assert image_tag(sha) == "sha-" + sha
    assert len(image_tag(sha)) == 44
    try:
        image_tag("abc")
    except SystemExit:
        pass
    else:
        raise AssertionError("short sha must be rejected")

    assert revision_suffix("ca-hms-scheduling", "sha-" + "a" * 12) == "sha-" + "a" * 12
    # The longest app name plus sha- and 40 hex is 63 characters, inside the 64 limit.
    long_tag = "sha-" + "b" * 40
    assert revision_suffix("ca-hms-scheduling", long_tag) == long_tag
    assert len("ca-hms-scheduling--" + long_tag) <= MAX_REVISION_NAME
    squeezed = revision_suffix("ca-hms-scheduling-extra", long_tag)
    assert squeezed != long_tag
    assert len("ca-hms-scheduling-extra--" + squeezed) <= MAX_REVISION_NAME

    no_change = plan(sha, "", "", ["apps/web/src/main.tsx"])
    assert no_change["deploy"] == "false" and no_change["build"] == "false"
    assert json.loads(no_change["matrix"]) == {"include": []}

    forced = plan(sha, "patients", "", [])
    assert forced["build"] == "true" and forced["services"] == "patients"
    assert forced["tag"] == image_tag(sha)

    emergency = plan(sha, "edge", "sha-" + "c" * 12, ["apps/web/src/x.tsx"])
    assert emergency["build"] == "false" and emergency["deploy"] == "true"
    assert emergency["services"] == "edge"
    assert json.loads(emergency["matrix"]) == {"include": []}

    all_tags = plan(sha, "", "sha-" + "d" * 7, [])
    assert all_tags["services"] == "identity,patients,scheduling,edge"
    assert all_tags["build"] == "false"

    root = Path(__file__).resolve().parents[2]
    for rel in DOCKERFILES.values():
        if not (root / rel).is_file():
            raise AssertionError(f"missing dockerfile {rel}")
    print("service_changes.py ok")


def main(argv: list[str]) -> None:
    if argv[1:] == ["--self-test"]:
        self_test()
        return
    if len(argv) < 2:
        raise SystemExit("usage: service_changes.py plan|order|suffix|--self-test")
    cmd = argv[1]
    if cmd == "order":
        for name in order(argv[2:]):
            print(name)
        return
    if cmd == "suffix":
        app = tag = ""
        args = argv[2:]
        for i, arg in enumerate(args):
            if arg == "--app":
                app = args[i + 1]
            elif arg == "--tag":
                tag = args[i + 1]
        if not app or not tag:
            raise SystemExit("suffix --app APP --tag TAG")
        print(revision_suffix(app, tag))
        return
    if cmd != "plan":
        raise SystemExit(f"unknown command {cmd}")
    sha = service = tag = ""
    files: list[str] = []
    args = argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--sha":
            sha = args[i + 1]
            i += 2
        elif args[i] == "--service":
            service = args[i + 1]
            i += 2
        elif args[i] == "--tag":
            tag = args[i + 1]
            i += 2
        elif args[i] == "--files":
            file_arg = args[i + 1]
            text = Path(file_arg).read_text(encoding="utf-8") if file_arg != "-" else sys.stdin.read()
            files = [line for line in text.splitlines() if line.strip()]
            i += 2
        else:
            raise SystemExit(f"unknown argument {args[i]}")
    emit(plan(sha, service, tag, files))


if __name__ == "__main__":
    main(sys.argv)
