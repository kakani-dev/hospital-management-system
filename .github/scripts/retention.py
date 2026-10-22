#!/usr/bin/env python3
"""What registry tags and Container Apps revisions a cleanup run may remove.

Safety rules (enforced here, not only by the caller):

- Delete only tags named sha-<7 to 40 hex>. Never delete any other tag.
- Always keep the newest 10 sha- tags of a repository.
- Always keep every tag that is deployed (the app template, any revision with
  traffic, any revision that still has replicas, and any revision that is
  Running or Activating). If no deployed image can be read, refuse to delete.
- Deactivate a revision only when it is still active, has no traffic, has no
  replicas, is not starting, and is outside the newest 3 revisions. The
  revision that is serving traffic is never returned.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SHA_TAG = re.compile(r"^sha-[0-9a-f]{7,40}$")
RUNNING_STATES = {"Running", "Activating", "Processing"}


def tag_from_image(image: str | None) -> str | None:
    if not image or "@" in image.rsplit("/", 1)[-1]:
        return None
    if ":" not in image:
        return None
    tag = image.rsplit(":", 1)[1]
    return tag or None


def tags_to_delete(tags_newest_first: list[str], protected_tags: set[str], keep: int = 10) -> list[str]:
    if keep < 1:
        raise SystemExit("keep must be at least 1")
    sha_tags = [tag for tag in tags_newest_first if SHA_TAG.fullmatch(tag)]
    # Preserve order, drop duplicates so a repeated tag is not deleted after being kept.
    seen: set[str] = set()
    ordered: list[str] = []
    for tag in sha_tags:
        if tag not in seen:
            seen.add(tag)
            ordered.append(tag)
    keep_set = set(ordered[:keep]) | {tag for tag in protected_tags if tag}
    return [tag for tag in ordered if tag not in keep_set]


def _props(revision: dict) -> dict:
    return revision.get("properties") or revision


def normalize_revision(revision: dict) -> dict:
    props = _props(revision)
    containers = (props.get("template") or {}).get("containers") or [{}]
    image = (containers[0] or {}).get("image") if containers else None
    replicas = props.get("replicas") or 0
    if isinstance(replicas, list):
        replicas = len(replicas)
    traffic = props.get("trafficWeight") or 0
    return {
        "name": revision.get("name") or props.get("name") or "",
        "created": props.get("createdTime") or "",
        "traffic": traffic or 0,
        "replicas": replicas or 0,
        "active": bool(props.get("active")),
        "image": image,
        "running": props.get("runningState") or "",
    }


def is_serving(revision: dict) -> bool:
    return bool(
        revision["traffic"] > 0
        or revision["replicas"] > 0
        or revision["running"] in RUNNING_STATES
    )


def revisions_to_deactivate(revisions: list[dict], keep: int = 3) -> list[str]:
    """Names of active revisions that are safe to deactivate."""
    if keep < 1:
        raise SystemExit("keep must be at least 1")
    rows = [normalize_revision(rev) if "traffic" not in rev or "created" not in rev else rev for rev in revisions]
    # Accept already-normalized rows (tests) and raw Azure rows.
    if rows and "name" in rows[0] and "created" not in rows[0]:
        rows = [normalize_revision(rev) for rev in revisions]
    newest = sorted(rows, key=lambda rev: (rev.get("created") or "", rev.get("name") or ""), reverse=True)
    kept = {rev["name"] for rev in newest[:keep] if rev.get("name")}
    doomed = []
    for rev in rows:
        name = rev.get("name") or ""
        if not name or name in kept or is_serving(rev) or not rev.get("active"):
            continue
        doomed.append(name)
    return doomed


def images_from_show(document: dict) -> list[str]:
    containers = (((document.get("properties") or {}).get("template") or {}).get("containers") or [])
    return [c.get("image") for c in containers if c.get("image")]


def protected_tags_from_files(paths: list[str]) -> set[str]:
    """Union of deployed image tags from `az containerapp show` and `revision list` JSON files."""
    tags: set[str] = set()
    saw_app = False
    for path in paths:
        document = json.loads(Path(path).read_text(encoding="utf-8"))
        images: list[str] = []
        if isinstance(document, dict) and "properties" in document and "template" in (document.get("properties") or {}):
            saw_app = True
            images.extend(images_from_show(document))
        revisions = document if isinstance(document, list) else document.get("value") or []
        if isinstance(revisions, list) and revisions and isinstance(revisions[0], dict) and (
            "properties" in revisions[0] or "name" in revisions[0]
        ):
            for rev in revisions:
                row = normalize_revision(rev)
                if is_serving(row) and row.get("image"):
                    images.append(row["image"])
                # The newest template image on a non-serving revision is not protected
                # unless it is also the app template (captured from show).
        for image in images:
            tag = tag_from_image(image)
            if tag:
                tags.add(tag)
    if not saw_app:
        raise SystemExit("refusing to delete tags: no container app document was found")
    if not tags:
        raise SystemExit("refusing to delete tags: no deployed image tag could be read")
    return tags


def self_test() -> None:
    newest = [f"sha-{index:012x}" for index in range(14, -1, -1)]  # 15 tags, index 14 first
    assert newest[0] == "sha-" + f"{14:012x}"
    protected = {newest[12]}
    deleted = tags_to_delete(newest, protected, keep=10)
    assert protected.isdisjoint(deleted)
    assert set(deleted) == {newest[10], newest[11], newest[13], newest[14]}
    assert tags_to_delete(["main", "sha-" + "a" * 12], set(), keep=10) == []
    assert tags_to_delete(["sha-NOTHEX", "latest"], {"sha-" + "a" * 12}, keep=10) == []
    # A deployed tag that is also in the newest 10 is kept, and nothing else old remains.
    assert tags_to_delete(newest[:3], {newest[2]}, keep=10) == []

    revisions = [
        {"name": "r5", "created": "2026-05-05T00:00:00Z", "traffic": 0, "replicas": 0, "active": True, "running": ""},
        {"name": "r4", "created": "2026-04-04T00:00:00Z", "traffic": 0, "replicas": 0, "active": True, "running": ""},
        {"name": "r3", "created": "2026-03-03T00:00:00Z", "traffic": 0, "replicas": 0, "active": True, "running": ""},
        {"name": "r2", "created": "2026-02-02T00:00:00Z", "traffic": 0, "replicas": 0, "active": True, "running": ""},
        {"name": "r1", "created": "2026-01-01T00:00:00Z", "traffic": 100, "replicas": 0, "active": True, "running": ""},
    ]
    assert revisions_to_deactivate(revisions, 3) == ["r2"]
    inactive = [dict(rev, active=False) if rev["name"] == "r2" else rev for rev in revisions]
    assert revisions_to_deactivate(inactive, 3) == []
    running_old = [dict(rev, traffic=0, replicas=1) if rev["name"] == "r1" else rev for rev in revisions]
    assert "r1" not in revisions_to_deactivate(running_old, 3)
    activating = [
        {"name": "new", "created": "2026-06-06T00:00:00Z", "traffic": 0, "replicas": 0, "active": True, "running": "Activating"},
        *revisions,
    ]
    assert "new" not in revisions_to_deactivate(activating, 3)

    raw = {
        "properties": {
            "template": {"containers": [{"image": "acrmedicorehmsdev.azurecr.io/hms-edge:sha-" + "ab" * 6}]},
            "trafficWeight": 100,
            "active": True,
            "runningState": "",
            "replicas": 0,
            "createdTime": "2026-01-01T00:00:00Z",
        },
        "name": "ca-hms-edge--sha",
    }
    assert tag_from_image(raw["properties"]["template"]["containers"][0]["image"]) == "sha-" + "ab" * 6
    assert is_serving(normalize_revision(raw))
    print("retention.py ok")


def main(argv: list[str]) -> None:
    if argv[1:] == ["--self-test"]:
        self_test()
        return
    if len(argv) < 2:
        raise SystemExit("usage: retention.py delete-tags|deactivate-revisions|protected-tags|--self-test")
    cmd = argv[1]
    if cmd == "protected-tags":
        tags = protected_tags_from_files(argv[2:])
        for tag in sorted(tags):
            print(tag)
        return
    if cmd == "delete-tags":
        keep = 10
        protected_path = ""
        args = argv[2:]
        i = 0
        while i < len(args):
            if args[i] == "--keep":
                keep = int(args[i + 1])
                i += 2
            elif args[i] == "--protected":
                protected_path = args[i + 1]
                i += 2
            else:
                raise SystemExit(f"unknown argument {args[i]}")
        if not protected_path:
            raise SystemExit("delete-tags requires --protected FILE (fail closed)")
        protected = {line.strip() for line in Path(protected_path).read_text(encoding="utf-8").splitlines() if line.strip()}
        if not protected:
            raise SystemExit("refusing to delete tags: protected tag file is empty")
        tags = [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]
        for tag in tags_to_delete(tags, protected, keep):
            print(tag)
        return
    if cmd == "deactivate-revisions":
        keep = 3
        args = argv[2:]
        i = 0
        while i < len(args):
            if args[i] == "--keep":
                keep = int(args[i + 1])
                i += 2
            else:
                raise SystemExit(f"unknown argument {args[i]}")
        document = json.load(sys.stdin)
        revisions = document if isinstance(document, list) else document.get("value") or []
        for name in revisions_to_deactivate(revisions, keep):
            print(name)
        return
    raise SystemExit(f"unknown command {cmd}")


if __name__ == "__main__":
    main(sys.argv)
