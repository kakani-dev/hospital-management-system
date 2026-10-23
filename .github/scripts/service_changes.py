#!/usr/bin/env python3
"""Which container images a commit needs to build and deploy.

Path rules (deploy order is always identity, patients, scheduling, billing, inventory, then edge):

- backend/platform, backend/shared, Directory.Build.props, Directory.Packages.props,
  global.json, a backend packages.lock.json (the NuGet lock), or .dockerignore
  change every image.
- .github/scripts/aca-rollout.sh, .github/scripts/service_changes.py,
  .github/scripts/aca-live-tags.sh, and .github/workflows/deploy-aca.yml also
  change every image. A rollout or plan change has to roll the apps that are
  already running, which a path filter on one service would skip.
- Each service image otherwise changes only with its own host and module.
- When live image tags are supplied, an app whose running tag is not the tag
  this commit would build is included too.
- The legacy gateway, the Vercel app, and SQL migrations do not select an image.
  This pipeline never deploys medicore-hms-api.

Image tags are sha- plus the full 40-character commit sha, matching the tags
already running in ACR (acrmedicorehmsdev.azurecr.io/hms-<svc>:sha-<40 hex>).
Revision names are "{app}--s-<first 12 hex>" and must be at most 54 characters.
The image tag is not shortened to make the revision name fit.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ORDER = ("identity", "patients", "scheduling", "billing", "inventory", "edge")

DOCKERFILES = {
    "identity": "backend/services/identity/Dockerfile",
    "patients": "backend/services/patients/Dockerfile",
    "scheduling": "backend/services/scheduling/Dockerfile",
    "billing": "backend/services/billing/Dockerfile",
    "inventory": "backend/services/inventory/Dockerfile",
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
    "billing": ("backend/services/billing/", "backend/modules/Billing/"),
    "inventory": ("backend/services/inventory/", "backend/modules/Inventory/"),
    "edge": ("backend/edge/",),
}
# Rollout and plan changes are not inside a service directory. They still have to
# publish every app, or a merge that only touches these files deploys nothing.
ALL_DEPLOY_FILES = {
    ".github/scripts/aca-rollout.sh",
    ".github/scripts/aca-live-tags.sh",
    ".github/scripts/service_changes.py",
    ".github/workflows/deploy-aca.yml",
}
# Basenames that rebuild every image when they sit at the repo root or under backend/.
# packages.lock.json is the NuGet lock (RestorePackagesWithLockFile); there is no
# lock file committed today, and a future one must not be filtered out.
SHARED_BASENAMES = {
    "Directory.Build.props",
    "Directory.Packages.props",
    "global.json",
    "packages.lock.json",
}

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
TAG_RE = re.compile(r"^sha-[0-9a-f]{7,40}$")
SUFFIX_RE = re.compile(r"^[a-z][a-z0-9-]*[a-z0-9]$")
# Azure rejects "{app}--{suffix}" longer than 54 characters. s- plus 12 hex fits
# every current app (ca-hms-scheduling--s-<12> is 33). The image tag stays full.
SUFFIX_HEX = 12
MAX_REVISION_NAME = 54
APPS = tuple(f"ca-hms-{service}" for service in ORDER)


def norm(path: str) -> str:
    path = path.strip().replace("\\", "/")
    while path.startswith("./"):
        path = path[2:]
    return path


def affects_all(path: str) -> bool:
    """True when this path is shared by every container image or by the deploy itself."""
    if path in SHARED_FILES or path in ALL_DEPLOY_FILES or path.startswith(SHARED_PREFIXES):
        return True
    base = path.rsplit("/", 1)[-1]
    if base not in SHARED_BASENAMES:
        return False
    return "/" not in path or path.startswith("backend/")


def services_for_paths(paths: list[str]) -> list[str]:
    """Return deploy-ordered service names touched by these paths."""
    normalized = [norm(p) for p in paths if norm(p)]
    if any(affects_all(path) for path in normalized):
        return list(ORDER)
    chosen = [
        service
        for service in ORDER
        if any(path.startswith(SERVICE_PREFIXES[service]) for path in normalized)
    ]
    return [service for service in ORDER if service in chosen]


def parse_live_tags(text: str) -> dict[str, str]:
    """Parse `service<TAB>tag` lines for every app. Missing or extra services fail closed."""
    found: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if "\t" not in line:
            raise SystemExit(f"live tag line must be service<TAB>tag, got {line!r}")
        service, tag = line.split("\t", 1)
        service, tag = service.strip(), tag.strip()
        if service not in ORDER:
            raise SystemExit(f"unknown service in live tags: {service}")
        if service in found:
            raise SystemExit(f"duplicate live tag for {service}")
        if not tag:
            raise SystemExit(f"{service} live image has no tag")
        found[service] = tag
    missing = [name for name in ORDER if name not in found]
    if missing:
        raise SystemExit(f"live image tags missing for {', '.join(missing)}")
    return found


def drifted_services(live_tags: dict[str, str], desired_tag: str) -> list[str]:
    """Apps whose running image tag is not the tag this commit builds."""
    missing = [name for name in ORDER if name not in live_tags]
    if missing:
        raise SystemExit(f"live image tags missing for {', '.join(missing)}")
    return [name for name in ORDER if live_tags[name] != desired_tag]


def image_tag(sha: str) -> str:
    """Tag pushed to ACR. Production apps run sha- plus the full 40-character commit sha."""
    if not SHA_RE.fullmatch(sha):
        raise SystemExit(f"sha must be 40 hex characters, got {sha!r}")
    return "sha-" + sha


def revision_suffix(app: str, tag: str) -> str:
    """Short revision suffix. The image tag is left unchanged.

    Azure names the revision "{app}--{suffix}" and rejects that string when it
    is longer than 54 characters. sha- plus a 40-character sha is already 44
    characters, so ca-hms-edge--sha-<40> is 57 and was rejected. The suffix is
    s- plus the first 12 hex characters of the tag (all of them when the tag
    is shorter). It is lowercase letters, digits, and single hyphens, and it
    starts with a letter.
    """
    if not TAG_RE.fullmatch(tag):
        raise SystemExit(f"image tag must look like sha-<hex>, got {tag!r}")
    if not app:
        raise SystemExit("app name is required")
    hexpart = tag.split("-", 1)[1]
    suffix = "s-" + hexpart[:SUFFIX_HEX]
    name = f"{app}--{suffix}"
    if (
        len(name) > MAX_REVISION_NAME
        or not SUFFIX_RE.fullmatch(suffix)
        or "--" in suffix
        or not name[0].isalpha()
    ):
        raise SystemExit(
            f"revision name {name} is not a valid Container Apps revision "
            f"({len(name)} characters; Azure allows at most {MAX_REVISION_NAME})"
        )
    return suffix


def order(names: list[str]) -> list[str]:
    unknown = [name for name in names if name not in ORDER]
    if unknown:
        raise SystemExit(f"unknown service(s): {', '.join(unknown)}. Choose from {', '.join(ORDER)}.")
    return [name for name in ORDER if name in names]


def matrix(services: list[str]) -> str:
    include = [{"service": service, "dockerfile": DOCKERFILES[service]} for service in services]
    return json.dumps({"include": include}, separators=(",", ":"))


def plan(
    sha: str,
    service: str,
    tag: str,
    paths: list[str],
    live_tags: dict[str, str] | None = None,
) -> dict[str, str]:
    if not SHA_RE.fullmatch(sha):
        raise SystemExit(f"sha must be 40 hex characters, got {sha!r}")
    service = service.strip()
    tag = tag.strip()
    if service and service not in ORDER:
        raise SystemExit(f"unknown service {service!r}. Choose one of {', '.join(ORDER)}, or leave it blank.")
    if tag and not TAG_RE.fullmatch(tag):
        raise SystemExit(f"tag must look like sha-<7-40 hex>, got {tag!r}")

    # Emergency hatch: an explicit service or tag stays narrow. Drift does not widen it.
    # An explicit tag is rolled as-is and nothing is built.
    if tag:
        services = [service] if service else list(ORDER)
        build = False
    elif service:
        services = [service]
        build = True
        tag = image_tag(sha)
    else:
        desired = image_tag(sha)
        selected = set(services_for_paths(paths))
        if live_tags is not None:
            selected.update(drifted_services(live_tags, desired))
        services = [name for name in ORDER if name in selected]
        build = bool(services)
        tag = desired

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
    assert services_for_paths([".github/workflows/deploy-aca.yml"]) == list(ORDER)
    assert services_for_paths([".github/scripts/aca-rollout.sh"]) == list(ORDER)
    assert services_for_paths([".github/scripts/service_changes.py"]) == list(ORDER)
    assert services_for_paths([".github/scripts/aca-live-tags.sh"]) == list(ORDER)
    assert services_for_paths(["backend/Directory.Build.props"]) == list(ORDER)
    assert services_for_paths(["backend/global.json"]) == list(ORDER)
    assert services_for_paths(["backend/services/identity/packages.lock.json"]) == list(ORDER)
    assert services_for_paths(["backend/shared/Hms.SharedKernel/Hms.SharedKernel.csproj"]) == list(ORDER)
    assert services_for_paths(
        ["backend/modules/Identity/Endpoints/Me.cs", ".github/workflows/deploy-aca.yml"]
    ) == list(ORDER)
    assert services_for_paths([".github/workflows/ci.yml", "docs/deploy.md"]) == []
    assert services_for_paths([".github/scripts/test-deploy-plan.sh"]) == []
    assert services_for_paths([".github/scripts/aca-cleanup-azure.sh"]) == []
    assert services_for_paths(["package-lock.json", "apps/web/package-lock.json"]) == []
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

    # The tag Azure rejected on the first main deploy (57 characters as a revision name).
    rejected = "b896ba108cf95c3193dbf7598d2882659a8c0da9"
    full_tag = image_tag(rejected)
    assert full_tag == "sha-" + rejected and len(full_tag) == 44
    assert ORDER == ("identity", "patients", "scheduling", "billing", "inventory", "edge")
    assert APPS == tuple(f"ca-hms-{service}" for service in ORDER)
    for app in APPS:
        suffix = revision_suffix(app, full_tag)
        name = f"{app}--{suffix}"
        assert suffix == "s-" + rejected[:SUFFIX_HEX]
        assert suffix != full_tag
        assert "--" not in suffix
        assert SUFFIX_RE.fullmatch(suffix)
        assert len(name) <= MAX_REVISION_NAME, name
    assert revision_suffix("ca-hms-scheduling", "sha-" + "a" * 12) == "s-" + "a" * 12
    assert revision_suffix("ca-hms-edge", "sha-" + "c" * 7) == "s-" + "c" * 7
    try:
        revision_suffix("a" * 41, full_tag)  # 41 + "--" + 14 = 57
    except SystemExit:
        pass
    else:
        raise AssertionError("a revision name over 54 characters must be rejected")

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
    assert all_tags["services"] == ",".join(ORDER)
    assert all_tags["build"] == "false"

    old = "sha-" + "ca54690f712413349eebc2f105812223d16702d0"
    assert len(old) == 44
    desired = image_tag(sha)
    current = {name: desired for name in ORDER}
    stale = {name: old for name in ORDER}
    assert drifted_services(current, desired) == []
    assert drifted_services(stale, desired) == list(ORDER)
    assert parse_live_tags("".join(f"{name}\t{old}\n" for name in ORDER)) == stale
    try:
        parse_live_tags(f"identity\t{old}\n")
    except SystemExit:
        pass
    else:
        raise AssertionError("incomplete live tags must be rejected")

    web_only = ["apps/web/src/main.tsx"]
    caught_up = plan(sha, "", "", web_only, current)
    assert caught_up["deploy"] == "false" and caught_up["build"] == "false"

    behind = plan(sha, "", "", web_only, stale)
    assert behind["deploy"] == "true" and behind["build"] == "true"
    assert behind["services"] == ",".join(ORDER)
    assert behind["tag"] == desired

    one = dict(current)
    one["scheduling"] = old
    partial = plan(sha, "", "", ["backend/services/patients/Dockerfile"], one)
    assert partial["services"] == "patients,scheduling"
    assert partial["build"] == "true" and partial["tag"] == desired

    # Emergency hatch stays narrow even when every running image is stale.
    pinned = plan(sha, "edge", "", web_only, stale)
    assert pinned["services"] == "edge" and pinned["build"] == "true"
    rolled = plan(sha, "", old, web_only, stale)
    assert rolled["services"] == ",".join(ORDER) and rolled["build"] == "false"
    assert rolled["tag"] == old

    # A merge that only touches the rollout/plan scripts still builds every image.
    scripted = plan(
        sha,
        "",
        "",
        [
            ".github/scripts/aca-rollout.sh",
            ".github/scripts/service_changes.py",
            ".github/workflows/deploy-aca.yml",
        ],
        current,
    )
    assert scripted["services"] == ",".join(ORDER)
    assert scripted["build"] == "true" and scripted["tag"] == desired

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
    live_tags: dict[str, str] | None = None
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
        elif args[i] == "--live":
            live_tags = parse_live_tags(Path(args[i + 1]).read_text(encoding="utf-8"))
            i += 2
        else:
            raise SystemExit(f"unknown argument {args[i]}")
    emit(plan(sha, service, tag, files, live_tags))


if __name__ == "__main__":
    main(sys.argv)
