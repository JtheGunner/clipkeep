#!/usr/bin/env python3
"""Generates the synthetic evaluation corpus and gold set (fictional data only).

    python3 eval/generate_synthetic.py

Writes eval/synthetic-corpus.json and eval/synthetic-gold.json. The output is deterministic.
"""
import json
import random
from pathlib import Path

rng = random.Random(20261027)

THEMES = {
    "swift": {
        "app": "Xcode",
        "words": "actor isolation sendable closure protocol extension generic optional struct enum "
        "concurrency task await async stream decoder encoder macro package target build".split(),
        "templates": [
            "func {a}{b}() async throws -> {c} {{ try await {d}.{e}() }}",
            "swift build failed: {a} cannot be {b} from a {c} context",
            "let {a} = {b}.{c}(with: {d}) // check {e} before shipping",
            "struct {A}{B}: {C} {{ var {a}: {b}; let {c}: {d} }}",
            "https://developer.example.org/docs/{a}/{b}-{c}",
        ],
    },
    "kubernetes": {
        "app": "Terminal",
        "words": "pod deployment ingress namespace cluster replica service rollout configmap "
        "volume node probe selector helm chart manifest context logs restart".split(),
        "templates": [
            "kubectl get {a} -n {b} -o wide | grep {c}",
            "kubectl rollout restart deployment/{a}-{b} --namespace {c}",
            "Error: {a} {b} not ready: {c} probe failed after {d} seconds",
            "helm upgrade --install {a} ./charts/{b} --set {c}.replicas=3",
            "https://cluster.example.org/{a}/{b}/{c}",
        ],
    },
    "kochen": {
        "app": "Safari",
        "words": "Zwiebel Knoblauch Rahm Pfanne Ofen Teig Mehl Butter Zucker Hefe Gemüse Suppe "
        "Pilze Kartoffeln Salz Pfeffer Kümmel Kräuter Käse Reis".split(),
        "templates": [
            "{a} und {b} in der {c} anbraten, dann {d} dazugeben",
            "Rezept: {a}-{b} mit {c}, 40 Minuten bei 180 Grad",
            "Einkaufsliste: {a}, {b}, {c}, {d}",
            "https://rezepte.example.org/{a}-{b}-{c}",
        ],
    },
    "reise": {
        "app": "Chrome",
        "words": "Flug Hotel Zug Reservation Buchung Gepäck Hauptbahnhof Terminal Gate Zimmer "
        "Frühstück Stornierung Bestätigung Reisepass Mietwagen Fahrplan Billett".split(),
        "templates": [
            "Buchung {a} bestätigt: {b} ab {c}, {d} inbegriffen",
            "Zug nach {a} um 0{n}:{m}, Umsteigen in {b}",
            "https://reisen.example.org/{a}/{b}?tag={c}",
            "Hotel {A} {B}, {a} {b}, Stornierung bis {n} Tage vorher",
        ],
    },
    "rechnung": {
        "app": "Numbers",
        "words": "Rechnung Betrag Mehrwertsteuer Konto Zahlung Frist Mahnung Quittung Budget "
        "Abrechnung Kunde Offerte Honorar Buchhaltung Beleg Spesen Steuer".split(),
        "templates": [
            "Rechnung Nr. {n}{m} an {A}: {a} {b}, Zahlungsfrist {c}",
            "Beleg {a} / {b}: CHF {n}{m}.50 inkl. {c}",
            "Offerte {A} {B} für {a} und {b}",
            "https://buchhaltung.example.org/{a}/{b}",
        ],
    },
    "schreiben": {
        "app": "Notes",
        "words": "Kapitel Entwurf Gliederung Zitat Quelle Absatz Einleitung Fazit Überschrift "
        "Lektorat Manuskript Notiz Idee Titel Thema Argument".split(),
        "templates": [
            "{A}: {a} überarbeiten, {b} kürzen, {c} ergänzen",
            "Idee für {a}: {b} gegen {c} stellen",
            "Gliederung {n}.{m} {a} und {b}",
            "https://zitate.example.org/{a}/{b}",
        ],
    },
}
NAMES = ["Meier", "Keller", "Frei", "Huber", "Graf", "Bauer", "Roth", "Steiner", "Weber", "Moser"]


def fill(template, words):
    pick = lambda: rng.choice(words)
    values = {k: pick() for k in "abcde"}
    values.update({k.upper(): rng.choice(NAMES) for k in "abc"})
    values.update({"n": rng.randint(1, 9), "m": rng.randint(10, 59)})
    return template.format(**values)


entries = []
session_no = 0
minute = 0.0
theme_names = list(THEMES)
order = [theme_names[i % len(theme_names)] for i in range(42)]
rng.shuffle(order)
for theme in order:
    config = THEMES[theme]
    minute += rng.uniform(40, 240)  # pause between sessions, above the 25 minute gap
    session_no += 1
    for index in range(rng.randint(5, 10)):
        minute += rng.uniform(0.5, 4)
        tag = f"s{session_no}e{index}"
        text = fill(rng.choice(config["templates"]), config["words"]) + f" ({tag})"
        entries.append(
            {
                "id": tag,
                "session": f"session-{session_no}",
                "theme": theme,
                "minute": round(minute, 2),
                "app": config["app"],
                "text": text,
            }
        )

# Gold queries: partial recall of what the user remembers about an entry.
queries = []
chosen = rng.sample(entries, 56)
for number, entry in enumerate(chosen):
    body = entry["text"].rsplit(" (", 1)[0]
    words = [w.strip(".,:;()/?=|-") for w in body.replace("/", " ").split()]
    words = [w for w in words if len(w) >= 4 and not w.startswith("http")]
    if not words:
        words = body.split()
    kind = number % 4
    if kind == 0 or len(words) < 2:
        query = rng.choice(words)
    elif kind == 1:
        query = " ".join(rng.sample(words, 2))
    elif kind == 2:
        word = rng.choice(words)
        query = word[: max(3, len(word) - 2)].lower()  # a remembered prefix
    else:
        query = " ".join(rng.sample(words, min(3, len(words)))).upper()
    queries.append({"query": query, "targetContains": f"({entry['id']})"})

root = Path(__file__).parent
(root / "synthetic-corpus.json").write_text(
    json.dumps({"entries": entries}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8"
)
(root / "synthetic-gold.json").write_text(
    json.dumps({"queries": queries}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8"
)
print(f"{len(entries)} entries, {session_no} sessions, {len(queries)} queries")
