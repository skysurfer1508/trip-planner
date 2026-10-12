"""OpenStreetMap `opening_hours` ("Mo-Fr 09:00-17:00; Sa 10:00-14:00; PH off"), ported from the iOS app (Services/Hours/OpeningHours.swift).

Understood: weekdays, public holidays (PH), months ("Oct-Apr: ..."), several time ranges, overnight hours, "off" and "24/7". Anything fancier
(weeks, sunrise, dates, open ends) is refused: `parse` returns None and nobody makes a claim about the place. The cases in tests/test_openinghours.py
are the ones in the app's own unit tests (InfoFeaturesTests.swift)."""
import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Callable

MONTHS = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12}
DAYS = {"mo": 1, "tu": 2, "we": 3, "th": 4, "fr": 5, "sa": 6, "su": 7}
WEEKDAY_DE = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
UNSUPPORTED = [r"week", r"sunrise", r"sunset", r"dusk", r"dawn", r"easter", r"\bsh\b", r"\+", r"\[", r"\|\|", r"\d{4}",
               r"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s*\d", r"\bopen\b", r"unknown"]
SPLIT = re.compile(r"(?<=\d),\s+(?=(?:Mo|Tu|We|Th|Fr|Sa|Su|PH|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b)")
TIMES = re.compile(r"^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$")

Interval = tuple[int, int]  # minutes after midnight; an end above 1440 means the next morning


@dataclass
class Rule:
    months: set[int] | None
    weekdays: set[int]  # ISO weekdays, 1 = Monday; empty means every day
    holiday: bool
    off: bool
    intervals: list[Interval]

    @property
    def holidays_only(self) -> bool:
        return not self.weekdays and self.holiday


def _span(a: int, b: int, limit: int) -> list[int]:
    return list(range(a, b + 1)) if a <= b else list(range(a, limit + 1)) + list(range(1, b + 1))


def _months(token: str) -> set[int] | None:
    found: set[int] = set()
    for part in token.lower().split(","):
        ends = part.split("-")
        if not 1 <= len(ends) <= 2 or ends[0] not in MONTHS:
            return None
        if len(ends) == 2:
            if ends[1] not in MONTHS:
                return None
            found.update(_span(MONTHS[ends[0]], MONTHS[ends[1]], 12))
        else:
            found.add(MONTHS[ends[0]])
    return found or None


def _weekdays(token: str) -> tuple[set[int], bool] | None:
    days: set[int] = set()
    holiday = False
    for part in token.lower().split(","):
        if part == "ph":
            holiday = True
            continue
        ends = part.split("-")
        if not 1 <= len(ends) <= 2 or ends[0] not in DAYS:
            return None
        if len(ends) == 2:
            if ends[1] not in DAYS:
                return None
            days.update(_span(DAYS[ends[0]], DAYS[ends[1]], 7))
        else:
            days.add(DAYS[ends[0]])
    return None if not days and not holiday else (days, holiday)


def _times(token: str) -> list[Interval] | None:
    out: list[Interval] = []
    for part in token.split(","):
        match = TIMES.match(part)
        if not match:
            return None
        h1, m1, h2, m2 = (int(g) for g in match.groups())
        if h1 > 24 or h2 > 24 or m1 >= 60 or m2 >= 60:
            return None
        start, end = h1 * 60 + m1, h2 * 60 + m2
        if end <= start:
            end += 1440
        out.append((start, end))
    return out or None


def _rule(text: str) -> Rule | None:
    months: set[int] | None = None
    weekdays: set[int] = set()
    holiday = off = False
    intervals: list[Interval] = []
    for raw in text.split():
        token = raw.strip(":")
        if token.lower() in ("off", "closed"):
            off = True
        elif (found := _months(token)) is not None:
            months = (months or set()) | found
        elif (days := _weekdays(token)) is not None:
            weekdays |= days[0]
            holiday = holiday or days[1]
        elif (times := _times(token)) is not None:
            intervals += times
        else:
            return None
    if not off and not intervals:
        return None
    return Rule(months, weekdays, holiday, off, intervals)


def parse(text: str) -> "OpeningHours | None":
    cleaned = re.sub(r'"[^"]*"', "", text).strip()
    if not cleaned:
        return None
    lower = cleaned.lower()
    if lower == "24/7":
        return OpeningHours([Rule(None, set(), False, False, [(0, 1440)])])
    if any(re.search(pattern, lower) for pattern in UNSUPPORTED):
        return None
    rules: list[Rule] = []
    for part in cleaned.split(";"):
        for piece in SPLIT.split(part):
            piece = piece.strip()
            if not piece:
                continue
            rule = _rule(piece)
            if rule is None:
                return None
            rules.append(rule)
    return OpeningHours(rules) if rules else None


def clock(minute: int) -> str:
    """Past midnight reads as the next morning (26:00 is 02:00); midnight itself stays 24:00."""
    value = 1440 if minute == 1440 else minute % 1440
    return f"{value // 60:02d}:{value % 60:02d}"


Holiday = Callable[[date], bool]
# A verdict is ("open",), ("opens_later", minute), ("closes_early", minute), ("closed", message) or ("unknown",).
Verdict = tuple


class OpeningHours:
    def __init__(self, rules: list[Rule]):
        self.rules = rules

    def _matches(self, rule: Rule, month: int, weekday: int, holiday: bool) -> bool:
        if rule.months is not None and month not in rule.months:
            return False
        if rule.holidays_only:
            return holiday
        if not rule.weekdays:
            return True
        return weekday in rule.weekdays or (rule.holiday and holiday)

    def _own(self, day: date, holiday: bool) -> tuple[str, list[Interval]]:
        """("closed"|"open"|"unknown", intervals) for one calendar day, without the hours spilling over from the day before."""
        result: tuple[str, list[Interval]] | None = None
        for rule in self.rules:
            if self._matches(rule, day.month, day.isoweekday(), holiday):
                result = ("closed", []) if rule.off else ("open", rule.intervals)
        if result:
            return result
        # Rules that only cover other months say nothing about this month; a covered month where no rule fits this weekday means closed.
        covered = any(rule.months is None or day.month in rule.months for rule in self.rules)
        return ("closed", []) if covered else ("unknown", [])

    def hours(self, day: date, is_holiday: Holiday) -> tuple[str, list[Interval]]:
        kind, intervals = self._own(day, is_holiday(day))
        yesterday = day - timedelta(days=1)
        before_kind, before = self._own(yesterday, is_holiday(yesterday))
        if before_kind == "open":
            spill = [(0, end - 1440) for _, end in before if end > 1440]
            if spill:
                if kind == "open":
                    intervals = spill + intervals
                elif kind == "closed":
                    kind, intervals = "open", spill
        return (kind, sorted(intervals)) if kind == "open" else (kind, intervals)

    def verdict(self, start: datetime, minutes: int, is_holiday: Holiday) -> Verdict:
        """Can you visit at `start` for `minutes`? Visits may overrun the closing time by 20 minutes."""
        def closed_message() -> str:
            return "An Feiertagen geschlossen" if is_holiday(start.date()) else f"{WEEKDAY_DE[start.weekday()]}s geschlossen"

        kind, intervals = self.hours(start.date(), is_holiday)
        if kind == "unknown":
            return ("unknown",)
        if kind == "closed":
            return ("closed", closed_message())
        begin = start.hour * 60 + start.minute
        finish = begin + minutes
        current = next((i for i in intervals if i[0] <= begin < i[1]), None)
        if current:
            end = current[1]
            if end == 1440:  # open until midnight and again from midnight (24/7): the visit may run on
                next_kind, next_day = self.hours(start.date() + timedelta(days=1), is_holiday)
                if next_kind == "open" and next_day and next_day[0][0] == 0:
                    end = 1440 + next_day[0][1]
            return ("open",) if finish <= end + 20 else ("closes_early", current[1])
        later = next((i for i in intervals if i[0] > begin), None)
        if later:
            return ("opens_later", later[0])
        own_kind, _ = self._own(start.date(), is_holiday(start.date()))
        if own_kind == "closed":  # only hours that spilled over from yesterday: today itself is closed
            return ("closed", closed_message())
        return ("closed", f"Geschlossen ab {clock(intervals[-1][1] if intervals else 0)}")


def warning(verdict: Verdict) -> str | None:
    """A short warning for a plan row, or None when everything is fine or unknown."""
    match verdict[0]:
        case "opens_later":
            return f"Öffnet um {clock(verdict[1])}, nach der geplanten Zeit"
        case "closes_early":
            return f"Schliesst um {clock(verdict[1])}, bevor der Besuch zu Ende ist"
        case "closed":
            return verdict[1]
    return None
