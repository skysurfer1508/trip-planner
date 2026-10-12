"""What kind of thing an idea is (temple, shopping, mountains …), to filter and colour the ideas on the map.

The list is in this order in the website too (web/src/categories.ts; a test keeps the two in step). `classify` guesses a category for
a place that has none: first the family's own places by exact name, then keywords in the name, then in the description."""

CATEGORIES: tuple[tuple[str, str], ...] = (
    ("temple", "Tempel & Schrein"),
    ("sight", "Sehenswürdigkeit"),
    ("museum", "Museum & Kunst"),
    ("nature", "Natur & Berge"),
    ("food", "Essen & Märkte"),
    ("shopping", "Shopping"),
    ("activity", "Aktivität & Erlebnis"),
    ("event", "Fest & Feuerwerk"),
    ("nightlife", "Abend & Nachtleben"),
    ("transport", "Anreise & Flughafen"),
    ("other", "Sonstiges"),
)
IDS = tuple(i for i, _ in CATEGORIES)

# The Japan 2027 ideas, by hand (the keyword rules below would get a few of them wrong).
KNOWN = {
    "Asakusa mit Senso-ji": "temple", "Shibuya Crossing": "sight", "Harajuku und Meiji-Schrein": "temple", "Akihabara": "shopping",
    "Tokyo Tower": "sight", "teamLab (Planets oder Borderless)": "museum", "Ghibli-Museum, Mitaka": "museum", "Shinjuku": "nightlife",
    "Sumida-Feuerwerk": "event", "Ueno-Park mit Museen": "museum", "Kamakura": "temple", "Nikko": "temple", "Hakone": "activity",
    "Fuji-Region (Kawaguchiko)": "nature", "Fuji-Besteigung": "nature", "Fushimi Inari": "temple", "Kinkaku-ji": "temple",
    "Arashiyama": "nature", "Gion und Higashiyama": "sight", "Gion Matsuri": "event", "Nishiki-Markt": "food", "Nara-Park und Todai-ji": "temple",
    "Dotonbori und Essen": "food", "Universal Studios Japan": "activity", "Burg Osaka": "sight", "Tenjin Matsuri": "event", "Himeji-Burg": "sight",
    "Hiroshima Friedenspark": "museum", "Miyajima": "sight", "Kamikochi": "nature", "Takayama und Shirakawa-go": "sight", "Matsumoto": "sight",
    "Jigokudani Snow Monkeys": "nature", "Karuizawa": "nature", "Tateyama Kurobe Alpine Route": "nature", "Kanazawa": "sight",
    "Furano und Biei": "nature", "Sapporo und Otaru": "sight", "Okinawa": "activity", "Uji": "food", "Kobe": "sight",
}

# Keyword rules, first match wins. Lower-case fragments.
RULES: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("transport", ("flughafen", "airport", "bahnhof", "shinkansen", "fähre")),
    ("event", ("matsuri", "feuerwerk", "festival", "fest ", "konzert", "parade")),
    ("temple", ("tempel", "schrein", "-ji", "jinja", "taisha", "-dera", "shrine", "temple", "torii", "kloster", "kirche", "kathedrale", "moschee")),
    ("museum", ("museum", "galerie", "gallery", "ausstellung", "teamlab", "kunst")),
    ("food", ("restaurant", "markt", "essen", "ramen", "sushi", "takoyaki", "okonomiyaki", "café", "cafe", "bar ", "imbiss", "street food", "bier", "weinprobe")),
    ("shopping", ("shopping", "einkauf", "outlet", "mall", "kaufhaus", "elektronik", "boutique", "souvenir")),
    ("activity", ("freizeitpark", "achterbahn", "onsen", "therme", "seilbahn", "schnorcheln", "tauchen", "kajak", "rafting", "ski", "spielhalle", "karaoke", "kochkurs", "workshop")),
    ("nature", ("berg", "gipfel", "see ", "wald", "park", "garten", "schlucht", "wasserfall", "strand", "insel", "wanderung", "wandern", "vulkan", "tal ", "alpen", "fluss")),
    ("nightlife", ("nachtleben", "club", "izakaya", "skyline", "aussichtsplattform", "abendstimmung", "rooftop")),
    ("sight", ("burg", "schloss", "turm", "altstadt", "viertel", "platz", "brücke", "denkmal", "aussicht", "stadt")),
)


def classify(name: str, description: str = "", region: str = "") -> str:
    if name in KNOWN:
        return KNOWN[name]
    if region.lower() == "flughafen":
        return "transport"
    for field in (name.lower() + " ", (description or "").lower() + " "):
        for category, words in RULES:
            if any(word in field for word in words):
                return category
    return "other"


# The app's stop categories (what a saved place carries) as an idea category.
FROM_STOP_CATEGORY = {"sight": "sight", "food": "food", "cafe": "food", "hotel": "other", "transport": "transport", "nightlife": "nightlife", "other": "other"}
