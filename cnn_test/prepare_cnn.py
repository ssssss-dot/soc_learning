"""Regenerate the real model package and the C program's exact layer answers."""
import argparse
import csv
from pathlib import Path
import subprocess
import sys

from export_layer_results import export_layer_results
from pack_model import ROOT


COUNTS = {"conv1": 4704, "pool1": 1176, "conv2": 1600, "pool2": 400,
          "fc1": 96, "fc2": 64, "fc3": 10}


def checksum(data):
    value = 0x13579BDF
    for byte in data:
        value = ((value << 5) | (value >> 27)) & 0xFFFFFFFF
        value = ((value ^ byte) + 0x9E3779B9) & 0xFFFFFFFF
    return value


def prepare(model_dir, out_dir):
    # Always recompute from current bins; an older CSV must not become golden.
    csv_path, prediction, label = export_layer_results(model_dir)
    subprocess.run([sys.executable, str(ROOT / "pack_model.py"),
                    "--model-dir", str(model_dir), "--out-dir", str(out_dir)], check=True)
    answers = {name: [] for name in COUNTS}
    with csv_path.open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            name = row["layer"]
            if name in answers:
                if int(row["index"]) != len(answers[name]):
                    raise ValueError(f"{name}: CSV indices must be contiguous")
                value = int(row["value_int8"])
                if not -128 <= value <= 127:
                    raise ValueError(f"{name}: value outside INT8 range")
                answers[name].append(value)
    lines = ["/* Generated from the current exported model; do not edit. */",
             "#ifndef CNN_REFERENCE_H", "#define CNN_REFERENCE_H", "#include <stdint.h>",
             f"#define CNN_MODEL_CHECKSUM 0x{checksum((out_dir / 'model_data.raw').read_bytes()):08X}u",
             f"#define CNN_REFERENCE_PREDICTION {prediction}u",
             f"#define CNN_REFERENCE_LABEL {label}u", ""]
    for name, count in COUNTS.items():
        values = answers[name]
        if len(values) != count:
            raise ValueError(f"{name}: expected {count} outputs, got {len(values)}")
        lines.append(f"static const int8_t cnn_expected_{name}[{count}] = {{")
        for start in range(0, count, 16):
            lines.append("    " + ", ".join(map(str, values[start:start + 16])) + ",")
        lines.extend(["};", ""])
    lines.extend(["#endif", ""])
    (out_dir / "cnn_reference.h").write_text("\n".join(lines), encoding="utf-8")
    print(f"Prepared exact references for 8050 outputs; prediction={prediction}, label={label}")
    return prediction, label


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, default=ROOT / "soc_export_int8")
    parser.add_argument("--out-dir", type=Path, default=ROOT / "ddr_model")
    args = parser.parse_args()
    prepare(args.model_dir.resolve(), args.out_dir.resolve())
