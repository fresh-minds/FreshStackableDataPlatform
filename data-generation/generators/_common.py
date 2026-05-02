"""Gedeelde helpers voor alle generators.

Deterministisch seeden, faker setup, header-comments.
"""
from __future__ import annotations

import random
from typing import Any

from faker import Faker


def make_rng(seed: int | None = None) -> random.Random:
    """Maak een deterministische RNG. Geen seed = systeem-rng."""
    return random.Random(seed) if seed is not None else random.Random()


def make_faker(seed: int | None = None, locale: str = "nl_NL") -> Faker:
    """Faker met NL-locale; deterministisch als seed gegeven."""
    f = Faker(locale)
    if seed is not None:
        Faker.seed(seed)
    return f


def envelope(record: dict[str, Any], event_type: str) -> dict[str, Any]:
    """Wrap een record in een Kafka-event-envelope.

    Velden:
      - event_id: opaque id (Kafka producer adds ts+offset later)
      - event_type: bv. 'persona.created', 'wia.aanvraag.ingediend'
      - schema_version: voor toekomstige evolutie
      - payload: het record zelf
      - meta.synthetic: altijd true voor deze repo
    """
    return {
        "event_type": event_type,
        "schema_version": "1.0.0",
        "payload": record,
        "meta": {"synthetic": True, "source": "data-generation"},
    }
