"""JR Pass or single tickets? Adds up the chosen legs that the pass covers and compares them with the pass prices.

The prices are the ordinary-class national JR Pass as published since October 2023. They can change (they did), so the answer says
which price list it used and the family must check the current prices before buying.
"""
from datetime import date
from typing import Any

from .rates import convert

PRICE_LIST = "JR Pass (Ordinary), Preisliste ab 1. Oktober 2023; vor dem Kauf auf japanrailpass.net prüfen"
PASSES = ((7, 50000), (14, 80000), (21, 100000))      # (days, JPY per adult)


def _day(value: str | None) -> date | None:
    try:
        return date.fromisoformat(value[:10]) if value else None
    except ValueError:
        return None


def compare(trip: dict[str, Any], hops: list[dict[str, Any]], table: dict[str, float] | None) -> dict[str, Any]:
    """`hops` as built by route.summarize. Only chosen legs count; a leg counts for the pass when it is marked pass_ok."""
    people = trip.get("travelers") or 1
    chosen = [h["chosen"] for h in hops if h["chosen"]]
    covered = [l for l in chosen if l.get("pass_ok")]
    other = [l for l in chosen if not l.get("pass_ok") and (l.get("price") or 0) > 0]
    singles = sum(l["price_in_trip_currency"] or 0 for l in covered)
    unknown = [l for l in covered if l["price_in_trip_currency"] is None]
    dates = sorted(d for d in (_day(l.get("departure")) for l in covered) if d)
    span = (dates[-1] - dates[0]).days + 1 if dates else None
    options = []
    for days, yen in PASSES:
        one = convert(yen, "JPY", trip["currency_code"], table)
        if one is None:
            continue
        options.append({"days": days, "price_per_person": round(one, 2), "price_for_group": round(one * people, 2),
                        "fits": None if span is None else span <= days,
                        "saves_for_group": round((singles - one) * people, 2)})
    best = next((o for o in options if o["fits"]), None) if span is not None else None
    notes: list[str] = []
    if not covered:
        notes.append("Noch keine Etappe ist als vom JR Pass gedeckt markiert. Bitte Claude, bei Zügen anzugeben, ob der Pass gilt (Nozomi und Mizuho gelten nicht).")
    if span is None and covered:
        notes.append("Ohne Abfahrtsdaten an den gedeckten Etappen lässt sich nicht sagen, welche Passdauer reicht. Der Pass gilt für aufeinanderfolgende Tage.")
    if unknown:
        notes.append("Bei einigen Etappen fehlt der Preis, der Vergleich ist deshalb zu günstig für die Einzeltickets.")
    if span is not None and span > PASSES[-1][0]:
        notes.append("Die gedeckten Fahrten liegen weiter auseinander als 21 Tage. Dann lohnen sich zwei kürzere Pässe oder Einzeltickets.")
    verdict = None
    if best and covered:
        verdict = "pass" if best["saves_for_group"] > 0 else "singles"
    return {"currency": trip["currency_code"], "travelers": people, "price_list": PRICE_LIST, "covered": len(covered), "not_covered_paid": len(other),
            "singles_per_person": round(singles, 2), "singles_for_group": round(singles * people, 2), "span_days": span,
            "options": options, "best_days": best["days"] if best else None, "verdict": verdict, "notes": notes}
