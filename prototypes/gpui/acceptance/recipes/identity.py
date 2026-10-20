"""Pure binding helper for IDs genuinely discovered after UI creation.

No fixed UUIDs or vector offsets stand in for created profiles/documents.
Workflow supplies isolated persisted records and a current capture epoch.
"""
from __future__ import annotations

import copy
import re
import uuid

REFERENCE = re.compile(r"capture\.([a-z][a-z0-9-]{0,63})\Z")


def valid_uuid(value):
    if not isinstance(value, str):
        raise ValueError("Persisted identity must be a canonical UUID.")
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        raise ValueError("Persisted identity must be a canonical UUID.") from None
    if str(parsed) != value or parsed.int == 0:
        raise ValueError("Persisted identity must be a canonical nonzero UUID.")
    return value


def discover_created(before_ids, after_records, *, engine, name_sha256, text_hash):
    """One matching NEW UI-created ID; no reading global libraries or secrets.

    text_hash is supplied by the caller's SHA256 helper, never a UI response.
    before_ids comes from the same isolated library before the Save action.
    """
    if (engine not in ("postgresql", "mysql") or not isinstance(name_sha256, str)
            or not re.fullmatch("[0-9a-f]{64}", name_sha256)):
        raise ValueError("Fixed synthetic engine/name hash is required.")
    def persisted_id(value):
        # Existing migrated libraries may retain opaque original IDs. Only a
        # newly UI-created captured identity must be a canonical nonzero UUID.
        if not isinstance(value, str) or not value or len(value.encode()) > 256 or any(ch in value for ch in '\0\r\n'):
            raise ValueError('Original persisted profile identity is invalid.')
        return value
    before_values = [persisted_id(value) for value in before_ids]
    before = set(before_values)
    if len(before_values) != len(before):
        raise ValueError('Original profile identities are duplicated.')
    ids = [persisted_id(row['id']) for row in after_records]
    if len(ids) != len(set(ids)):
        raise ValueError("Duplicate persisted identities refuse discovery.")
    if not before.issubset(set(ids)):
        raise ValueError("Original profiles disappeared during UI creation.")
    matching = [row["id"] for row in after_records
                if row["id"] not in before and row.get("engine") == engine
                and isinstance(row.get("name"), str) and text_hash(row["name"]) == name_sha256]
    if len(matching) != 1:
        raise ValueError("Exactly one newly UI-created synthetic profile is required.")
    return valid_uuid(matching[0])


def resolve_profile(reference, captures, current_profile_ids):
    match = REFERENCE.fullmatch(reference) if isinstance(reference, str) else None
    if not match or match[1] not in captures:
        raise ValueError("An existing captured UI-created identity is required.")
    value = valid_uuid(captures[match[1]])
    if value not in {valid_uuid(item) for item in current_profile_ids}:
        raise ValueError("Captured profile no longer belongs to the isolated library.")
    return value


def bind_policy_assertion(item, captures, current_profile_ids):
    """Adapt one supported DSL operation after explicit current-owner checking.

    Workflow uses the same narrow resolver with an additional epoch. Resolves only profileId, never arbitrary
    item strings, native IDs, paths, values or application error text.
    """
    if item.get("op") != "assert-profile-policy":
        raise ValueError("Only the exact profile policy assertion can be bound.")
    result = copy.deepcopy(item)
    result["profileId"] = resolve_profile(item.get("profileId"), captures, current_profile_ids)
    return result
