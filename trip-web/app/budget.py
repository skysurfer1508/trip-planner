"""The budget screen's numbers (BudgetView.swift): everything in the trip currency, per category and per day, what is planned in
stops, and which expenses could not be converted (those count at face value in the app and are listed here instead)."""
from typing import Any

from .rates import convert

CATEGORIES = ("food", "transport", "lodging", "activities", "shopping", "other")


def summarize(trip: dict[str, Any], expenses: list[dict[str, Any]], stops: list[dict[str, Any]], table: dict[str, float] | None) -> dict[str, Any]:
    base = trip["currency_code"]
    converted: dict[str, float | None] = {}
    for e in expenses:
        converted[e["id"]] = convert(e["amount"], e["currency_code"], base, table)
    spent = sum(v for v in converted.values() if v is not None)
    budget = trip.get("budget") or 0
    by_category = [{"category": c, "total": round(t, 2)} for c in CATEGORIES
                   if (t := sum(converted[e["id"]] or 0 for e in expenses if e.get("category_raw", "other") == c)) != 0]
    days: dict[str, float] = {}
    for e in expenses:
        days[e["date"]] = days.get(e["date"], 0) + (converted[e["id"]] or 0)
    return {
        "currency": base, "budget": budget, "spent": round(spent, 2), "left": round(budget - spent, 2),
        "percent": round(spent / budget * 100, 1) if budget > 0 else None, "over": budget > 0 and spent > budget,
        "planned": round(sum(s.get("estimated_cost") or 0 for s in stops), 2),
        "by_category": by_category, "by_day": [{"date": d, "total": round(t, 2)} for d, t in sorted(days.items())],
        "converted": {k: (round(v, 2) if v is not None else None) for k, v in converted.items()},
        "unconverted": [{"id": e["id"], "title": e["title"], "currency": e["currency_code"]} for e in expenses if converted[e["id"]] is None],
        "rates_known": table is not None,
    }
