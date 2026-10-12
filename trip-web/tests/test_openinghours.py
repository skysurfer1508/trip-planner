"""The cases of OpeningHoursTests in the iOS app (InfoFeaturesTests.swift); 2026-10-05 is a Monday, 2026-06-02 a Tuesday."""
from datetime import datetime

import pytest

from app import openinghours as oh


def verdict(rules, month, day, hour=12, minute=0, minutes=60, holiday=()):
    hours = oh.parse(rules)
    assert hours is not None, f"should parse: {rules}"
    return hours.verdict(datetime(2026, month, day, hour, minute), minutes, lambda d: d.isoformat() in holiday)


def test_weekdays_only():
    assert verdict("Mo-Fr 09:00-17:00", 10, 6, 10) == ("open",)
    assert verdict("Mo-Fr 09:00-17:00", 10, 10, 10) == ("closed", "Samstags geschlossen")
    assert verdict("Mo-Fr 09:00-17:00", 10, 5, 18) == ("closed", "Geschlossen ab 17:00")
    assert verdict("Mo-Fr 09:00-17:00", 10, 5, 7) == ("opens_later", 9 * 60)


def test_seasonal_rules_like_torre_de_belem():
    torre = "Oct-Apr: Tu-Su 10:00-17:30; May-Sep: Tu-Su 10:00-18:30"
    assert verdict(torre, 10, 6, 16) == ("open",)
    assert verdict(torre, 10, 6, 17, minutes=90) == ("closes_early", 17 * 60 + 30)
    assert verdict(torre, 10, 5, 11) == ("closed", "Montags geschlossen")
    assert verdict(torre, 6, 2, 18, minutes=30) == ("open",)


def test_a_month_the_rules_do_not_cover_is_unknown():
    assert verdict("Jun-Aug Mo-Su 10:00-18:00", 10, 6, 12) == ("unknown",)
    assert verdict("Jun-Aug Mo-Su 10:00-18:00", 6, 2, 12) == ("open",)


def test_lunch_break():
    assert verdict("Mo-Su 09:00-12:00,14:00-18:00", 10, 6, 13) == ("opens_later", 14 * 60)
    assert verdict("Mo-Su 09:00-12:00,14:00-18:00", 10, 6, 15) == ("open",)


def test_public_holidays_and_off():
    rules = "Mo-Sa 10:00-20:00; Su off; PH off"
    assert verdict(rules, 10, 6, 12) == ("open",)
    assert verdict(rules, 10, 6, 12, holiday={"2026-10-06"}) == ("closed", "An Feiertagen geschlossen")
    assert verdict(rules, 10, 11, 12) == ("closed", "Sonntags geschlossen")


def test_always_open():
    assert verdict("24/7", 10, 6, 3) == ("open",)
    assert verdict("24/7", 10, 10, 23, 30, minutes=120) == ("open",)


def test_overnight_hours_spill_into_the_next_morning():
    assert verdict("Mo-Fr 22:00-02:00", 10, 6, 1, minutes=30) == ("open",)       # Monday night runs into Tuesday
    assert verdict("Mo-Fr 22:00-02:00", 10, 10, 1, minutes=30) == ("open",)      # Friday night runs into Saturday
    assert verdict("Mo-Fr 22:00-02:00", 10, 10, 23, minutes=30) == ("closed", "Samstags geschlossen")


def test_comma_separated_rules_and_comments():
    rules = 'Mo-Fr 09:00-12:00, Sa 10:00-14:00 "by appointment on Sundays"'
    assert verdict(rules, 10, 10, 11) == ("open",)
    assert verdict(rules, 10, 10, 15) == ("closed", "Geschlossen ab 14:00")
    assert verdict(rules, 10, 6, 10) == ("open",)


@pytest.mark.parametrize("text", ["sunrise-sunset", 'Mo-Fr 09:00-17:00 || "on appointment"', "week 1-53/2 Mo 10:00-12:00", "Dec 25 off",
                                  "Mo-Fr 10:00+", "Mo[1] 10:00-12:00", "Mo-Fr dusk-dawn", "", "Mo-Fr"])
def test_rules_the_parser_cannot_check_are_refused(text):
    assert oh.parse(text) is None


def test_warning_texts():
    assert oh.warning(("open",)) is None and oh.warning(("unknown",)) is None
    assert oh.warning(("opens_later", 600)) == "Öffnet um 10:00, nach der geplanten Zeit"
    assert oh.warning(("closes_early", 1050)) == "Schliesst um 17:30, bevor der Besuch zu Ende ist"
    assert oh.warning(("closed", "Montags geschlossen")) == "Montags geschlossen"
