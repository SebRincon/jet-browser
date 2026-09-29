"""Synthetic scaling probes, reported separately from diagnostic accuracy."""
from .tasks import schema, enum, boolean

CASES = []
for cardinality in [64, 255]:
    choices = [f"tariff_{i:03d}" for i in range(cardinality)]
    s = schema(tariff=enum("Copy the exact tariff code in the text", *choices))
    CASES.append((f"enum-{cardinality}", s, f"The assigned tariff code is {choices[-2]}.", {"tariff": choices[-2]}))
for count in [12, 28]:
    fields = {f"flag_{i:02d}": boolean(f"True if item {i:02d} is enabled; false if disabled") for i in range(count)}
    expected = {name: i % 2 == 0 for i, name in enumerate(fields)}
    context = "\n".join(f"Item {i:02d} is {'enabled' if i % 2 == 0 else 'disabled'}." for i in range(count))
    CASES.append((f"fields-{count}", schema(**fields), context, expected))
s = schema(signal=enum("Copy the final signal color", "red", "green", "blue"))
context = "Archive entries follow.\n" + "An old record was checked and filed.\n" * 160 + "\nFinal signal color: blue."
CASES.append(("long-context", s, context, {"signal":"blue"}))
