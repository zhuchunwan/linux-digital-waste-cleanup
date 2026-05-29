#!/usr/bin/env python3
"""Generate lab-ops/test fixtures."""
from pathlib import Path
import json

root = Path(__file__).resolve().parent


def write_bytes(p: Path, data: bytes) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)


def write_text(p: Path, text: str) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8", newline="\n")


chunk = ("LAB_DEDUPE_PAYLOAD_v2|" + "X" * 200 + "\n").encode() * 6
assert len(chunk) > 1024

for name in ("triple_x.bin", "triple_y.bin", "triple_z.bin"):
    write_bytes(root / "dup" / name, chunk)

for rel in (
    "dup_nested/proj_a/result.out",
    "dup_nested/proj_b/result.out",
    "dup_nested/backup/result_copy.out",
):
    write_bytes(root / rel, chunk)

write_bytes(root / "datasets/backup_copy.bin", chunk)

small = b"SMALL_DUP_PAIR_" + b"z" * 80
assert len(small) < 1024
write_bytes(root / "dup/small_dup_a.txt", small)
write_bytes(root / "dup/small_dup_b.txt", small)

png = bytes(
    [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC,
        0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    ]
)
write_bytes(root / "images/pixel.png", png)

jpeg = b"\xFF\xD8\xFF\xE0" + b"\x00" * 1100 + b"\xFF\xD9"
write_bytes(root / "images/scan_sample.jpg", jpeg)

write_text(
    root / "datasets/config.json",
    json.dumps({"project": "lab-ops-test", "epochs": 3, "batch": 32}, indent=2) + "\n",
)
write_text(root / "datasets/labels.tsv", "id\tlabel\n1\tcat\n2\tdog\n")
write_text(root / "papers/reference.bib", "@article{demo2026, title={Test}, year={2026}}\n")
write_text(root / "papers/notes", "No extension file for audit.\n")
write_text(root / "archives/fragment.part01", "PART1" + "A" * 500 + "\n")
write_text(root / "archives/fragment.part02", "PART2" + "B" * 500 + "\n")
write_text(root / "archives/__MACOSX/._junk", "macosx metadata junk\n")
write_text(root / "mixed/data,with,commas.csv", "a,b,c\n1,2,3\n")
write_text(root / "no_ext/README", "file without dot in name\n")
write_text(root / "code/train.py", '#!/usr/bin/env python3\nprint("train")\n')
write_text(root / "code/eval.R", 'cat("eval R script\\n")\n')
write_bytes(root / "edge_cases/empty_file", b"")
write_text(root / "edge_cases/tiny.txt", "hi\n")
write_text(root / "edge_cases/only_extension.", "trailing dot name\n")
write_text(root / "datasets/large_notes.txt", "NOTE|" + ("L" * 1500) + "\n")

print(f"fixtures ready: {sum(1 for p in root.rglob('*') if p.is_file())} files under {root}")
