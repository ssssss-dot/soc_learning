"""Build camera inference (default) or model self-test and both Loader images.

Example on server142, from the folder containing this script and model bins:
    python3 build_cnn.py --llvm-bin /home/shenjiexiang/llvm-project/build/bin
    python3 build_cnn.py --llvm-bin /home/shenjiexiang/llvm-project/build/bin --self-test
"""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess

from pack_model import ROOT, loader_packet
from prepare_cnn import prepare


def read_elf(path):
    """Read ELF32 little-endian RISC-V sections without requiring objcopy."""
    data = path.read_bytes()
    if (data[:6] != b"\x7fELF\x01\x01" or
            struct.unpack_from("<HH", data, 16) != (2, 243)):
        raise ValueError("Expected an executable ELF32 little-endian RISC-V file")
    entry, = struct.unpack_from("<I", data, 24)
    shoff, = struct.unpack_from("<I", data, 32)
    entsize, count, names_index = struct.unpack_from("<HHH", data, 46)
    if entry != 0 or entsize != 40 or not count or names_index >= count:
        raise ValueError("ELF entry must be zero and section table must be valid")
    headers = [struct.unpack_from("<10I", data, shoff + i * entsize) for i in range(count)]
    name_header = headers[names_index]
    names = data[name_header[4]:name_header[4] + name_header[5]]
    sections = {}
    for h in headers:
        name = names[h[0]:].split(b"\0", 1)[0].decode("ascii")
        sections[name] = (h[3], data[h[4]:h[4] + h[5]] if h[1] != 8 else b"", h[5])
    return sections


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--llvm-bin", type=Path, required=True)
    default_model_dir = ROOT / "soc_export_int8"
    if not default_model_dir.is_dir() and (ROOT.parent / "parameter_example").is_dir():
        default_model_dir = ROOT.parent / "parameter_example"
    parser.add_argument("--model-dir", type=Path, default=default_model_dir)
    parser.add_argument("--out-dir", type=Path, default=ROOT / "build" / "cnn")
    parser.add_argument("--march", default="rv32i", help="Use rv32i_zicsr if a newer LLVM requires it")
    parser.add_argument("--polling", action="store_true", help="Use the original MMIO polling completion path")
    parser.add_argument("--self-test", action="store_true", help="Use exported test image and compare all 8050 layer outputs")
    parser.add_argument("--frames", type=int, default=0, help="Stop camera inference after N frames; 0 means continuous")
    args = parser.parse_args()
    if not 0 <= args.frames <= 0xFFFFFFFF:
        parser.error("--frames must be in the range 0..4294967295")
    if args.self_test and args.frames:
        parser.error("--frames is only valid for camera input")
    out = args.out_dir.resolve()
    assets = out / "assets"
    suffix = ".exe" if os.name == "nt" else ""
    clang = args.llvm_bin / ("clang" + suffix)
    linker = args.llvm_bin / ("ld.lld" + suffix)
    for tool in (clang, linker):
        if not tool.is_file():
            parser.error(f"Required tool not found: {tool}")
    prediction, label = prepare(args.model_dir.resolve(), assets)
    obj = out / "cnn_inference.o"
    elf = out / "cnn_inference.elf"
    compile_command = [str(clang), "--target=riscv32", "-march=" + args.march,
                       "-mabi=ilp32", "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror",
                       "-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-fno-pic",
                       "-mno-relax", "-msmall-data-limit=0", "-ffunction-sections",
                       "-fdata-sections", "-fno-jump-tables", "-I", str(assets),
                       "-c", str(ROOT / "cnn_inference.c"), "-o", str(obj)]
    compile_command.insert(1, "-DCNN_USE_INTERRUPTS=" + ("0" if args.polling else "1"))
    compile_command.insert(1, "-DCNN_CAMERA_INPUT=" + ("0" if args.self_test else "1"))
    compile_command.insert(1, "-DCNN_CAMERA_MAX_FRAMES=" + str(args.frames) + "u")
    subprocess.run(compile_command, check=True)
    subprocess.run([str(linker), "-m", "elf32lriscv", "--no-relax", "--gc-sections",
                    "-T", str(ROOT / "linker_cnn.ld"), "-Map=" + str(out / "cnn_inference.map"),
                    str(obj), "-o", str(elf)], check=True)
    sections = read_elf(elf)
    text_addr, text, _ = sections[".text"]
    data_addr, program_data, _ = sections[".data"]
    bss_addr, _, bss_size = sections[".bss"]
    if (text_addr != 0 or len(text) > 128 * 1024 or data_addr != 0x80000000 or
            not program_data or len(program_data) > 60 * 1024 or
            bss_addr + bss_size > 0x8000F000):
        raise ValueError("Firmware does not fit the reserved memory/stack layout")
    if len(text) % 4:
        raise ValueError("RV32I text must be word-aligned")
    for offset in range(0, len(text), 4):
        word, = struct.unpack_from("<I", text, offset)
        if word & 3 != 3:
            raise ValueError(f"Compressed instruction or data in .text at 0x{offset:X}")
        if word & 0x7F == 0x33 and word >> 25 == 1:
            raise ValueError(f"Unsupported M-extension instruction at 0x{offset:X}")
    (out / "cnn_iram.raw").write_bytes(text)
    (out / "cnn_program_dmem.raw").write_bytes(program_data)
    # Both Loader regions are 128 KiB; only their preamble/base mapping differs.
    (out / "cnn_iram.bin").write_bytes(b"\xc0" * 4 + loader_packet(text, 0)[4:])
    program_packet = loader_packet(program_data, 0)
    (out / "cnn_program_dmem.bin").write_bytes(program_packet)
    model = (assets / "model_data.raw").read_bytes()
    merged = bytearray(0x10000 + len(model))
    merged[:len(program_data)] = program_data
    merged[0x10000:] = model
    (out / "cnn_dmem.bin").write_bytes(loader_packet(bytes(merged), 0))
    (out / "build_info.json").write_text(json.dumps({
        "completion_mode": "polling" if args.polling else "interrupts",
        "input_source": "exported_model_image" if args.self_test else "camera",
        "camera_frame_limit": args.frames,
        "camera_ddr_address": "0x10020000" if not args.self_test else None,
        "model_dir": str(args.model_dir.resolve()), "prediction": prediction, "label": label,
        "text_bytes": len(text), "program_data_bytes": len(program_data), "bss_bytes": bss_size,
        "model_bytes": len(model), "dmem_payload_bytes": len(merged), "stack_top": "0x80010000",
        "model_checksum": (assets / "cnn_reference.h").read_text().split("CNN_MODEL_CHECKSUM ", 1)[1].splitlines()[0],
        "compile_command": compile_command,
    }, indent=2) + "\n", encoding="utf-8")
    print(f"Built: {elf}")
    print("Input: " + ("exported image self-test (8050 comparisons)" if args.self_test else "camera (32x32 INT8, DDR 0x10020000)"))
    print(f"Firmware: text={len(text)}, data={len(program_data)}, bss={bss_size} bytes")
    print(f"Download: {out / 'cnn_iram.bin'} and {out / 'cnn_dmem.bin'}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        raise SystemExit(
            f"build_cnn: command failed (exit {exc.returncode}); see the messages above."
        ) from None
    except (OSError, ValueError, KeyError, struct.error) as exc:
        raise SystemExit(f"build_cnn: {exc}") from None
