"""Tests voor BSN 11-proef.

Run:
  cd data-generation && uv run pytest -v
"""
from __future__ import annotations

import random

import pytest

from generators.persona import (
    BSN_WEIGHTS_8,
    BSN_WEIGHTS_9,
    calculate_bsn_check_digit,
    generate_test_bsn,
    is_valid_bsn,
)


# Publieke testvoorbeelden uit literatuur (geen echte BSN's).
KNOWN_VALID = ["111222333", "123456782"]


@pytest.mark.parametrize("bsn", KNOWN_VALID)
def test_known_valid_bsns(bsn: str) -> None:
    assert is_valid_bsn(bsn)


@pytest.mark.parametrize(
    "bsn",
    [
        "000000000",   # alle nullen
        "111111111",   # eenvoud
        "12345",       # te kort
        "1234567890",  # te lang
        "abcdefghi",   # niet-numeriek
        "012345678",   # leading zero
        "",            # leeg
    ],
)
def test_known_invalid_bsns(bsn: str) -> None:
    assert not is_valid_bsn(bsn)


def test_generate_test_bsn_starts_with_9() -> None:
    rng = random.Random(42)
    for _ in range(100):
        bsn = generate_test_bsn(rng)
        assert bsn.startswith("9")
        assert len(bsn) == 9
        assert bsn.isdigit()


def test_generate_test_bsn_passes_11_proef() -> None:
    """1000 gegenereerde BSN's moeten allemaal de 11-proef doorstaan."""
    rng = random.Random(2026)
    for _ in range(1000):
        assert is_valid_bsn(generate_test_bsn(rng))


def test_check_digit_matches_11_proef() -> None:
    """Voor alle prefix-cijfers: het berekende 9e cijfer maakt de BSN geldig."""
    rng = random.Random(7)
    for _ in range(50):
        first_8 = "9" + "".join(str(rng.randint(0, 9)) for _ in range(7))
        check = calculate_bsn_check_digit(first_8)
        if check is None:
            continue
        bsn = first_8 + str(check)
        assert is_valid_bsn(bsn)


def test_weights_sum() -> None:
    """De weights-tuples zijn goed gedefinieerd."""
    assert BSN_WEIGHTS_8 == (9, 8, 7, 6, 5, 4, 3, 2)
    assert BSN_WEIGHTS_9 == (9, 8, 7, 6, 5, 4, 3, 2, -1)


def test_calculate_check_digit_invalid_input_length() -> None:
    with pytest.raises(ValueError):
        calculate_bsn_check_digit("1234")
