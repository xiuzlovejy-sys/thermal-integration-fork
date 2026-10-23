"""Check the two ObjC PAC schemas required by the current iOS probe."""

import argparse
import json
from pathlib import Path
import struct


def inspect_object(data):
    def unpack(layout, offset):
        length = struct.calcsize(layout)
        if offset < 0 or offset + length > len(data):
            raise ValueError("truncated Mach-O structure")
        return struct.unpack_from(layout, data, offset)

    magic, cpu, subtype, filetype, count, command_size, flags, reserved = unpack("<8I", 0)
    if magic != 0xFEEDFACF or filetype != 1:
        raise ValueError("expected a thin little-endian 64-bit Mach-O object")
    if command_size > len(data) - 32 or count > command_size // 8:
        raise ValueError("invalid load command bounds")
    sections = []
    symbol_table = None
    position = 32
    for _ in range(count):
        command, size = unpack("<II", position)
        if size < 8 or position + size > 32 + command_size:
            raise ValueError("invalid load command size")
        if command == 0x19:
            section_count = unpack("<I", position + 64)[0]
            if size < 72 or 72 + 80 * section_count > size:
                raise ValueError("invalid section list")
            for index in range(section_count):
                start = position + 72 + 80 * index
                name, segment, address, length, offset, alignment, relocations, relocation_count, *unused = unpack(
                    "<16s16sQQ8I", start
                )
                if offset + length > len(data) or relocations + 8 * relocation_count > len(data):
                    raise ValueError("invalid section or relocation bounds")
                sections.append({
                    "name": name.rstrip(b"\0").decode(),
                    "address": address, "offset": offset, "length": length,
                    "relocations": relocations, "count": relocation_count,
                })
        elif command == 2:
            symbol_table = unpack("<4I", position + 8)
        position += size
    if symbol_table is None:
        raise ValueError("missing symbol table")
    symbol_offset, symbol_count, string_offset, string_size = symbol_table
    if symbol_offset + 16 * symbol_count > len(data) or string_offset + string_size > len(data):
        raise ValueError("invalid symbol or string bounds")
    symbols = []
    for index in range(symbol_count):
        string_index, kind, section, description, value = unpack("<IBBHQ", symbol_offset + 16 * index)
        if string_index >= string_size:
            raise ValueError("invalid symbol name offset")
        start = string_offset + string_index
        end = data.find(b"\0", start, string_offset + string_size)
        if end < 0:
            raise ValueError("unterminated symbol name")
        symbols.append({"name": data[start:end].decode(), "section": section, "value": value})
    references = []
    for section_index, section in enumerate(sections, 1):
        for index in range(section["count"]):
            location, info = unpack("<iI", section["relocations"] + 8 * index)
            if info & 0x80000000 and location < 0:
                raise ValueError("unsupported scattered relocation")
            external = bool(info & (1 << 27))
            symbol_index = info & 0xFFFFFF
            if external and symbol_index >= len(symbols):
                raise ValueError("invalid relocation symbol")
            if (info >> 25) & 3 != 3:
                continue
            if location < 0 or location + 8 > section["length"]:
                raise ValueError("invalid pointer relocation location")
            raw = unpack("<Q", section["offset"] + location)[0]
            references.append({
                "section_index": section_index,
                "location": location,
                "symbol": symbols[symbol_index]["name"] if external else None,
                "type": info >> 28,
                "length": (info >> 25) & 3,
                "key": (raw >> 49) & 3,
                "address_diversity": bool(raw & (1 << 48)),
                "discriminator": (raw >> 32) & 0xFFFF,
                "authenticated_marker": bool(raw & (1 << 63)),
            })
    errors = []
    checks = {}
    if cpu != 0x0100000C or subtype != 0x80000002:
        errors.append("expected the current arm64e USR00 subtype 0x80000002")

    def check_reference(label, candidates, discriminator):
        candidate = next((item for item in candidates if item["type"] == 11), None)
        if candidate is None:
            checks[label] = candidates
            errors.append(label + ": missing authenticated-pointer relocation")
            return
        checks[label] = candidate
        if not (
            candidate["length"] == 3 and candidate["key"] == 2
            and candidate["address_diversity"] and candidate["authenticated_marker"]
            and candidate["discriminator"] == discriminator
        ):
            errors.append(label + ": pointer authentication schema does not match the tested runtime")

    fixture = next((item for item in symbols if item["name"] == "_OBJC_CLASS_$_CLPCABIFixture"), None)
    if fixture is None or not 1 <= fixture["section"] <= len(sections):
        errors.append("missing CLPCABIFixture class definition")
    else:
        section = sections[fixture["section"] - 1]
        slot = fixture["value"] + 8 - section["address"]
        candidates = [item for item in references if item["section_index"] == fixture["section"]
                      and item["location"] == slot and item["symbol"] == "_OBJC_CLASS_$_NSObject"]
        check_reference("superclass", candidates, 0xB5AB)
    blocks = [item for item in references if item["symbol"] in
              ("__NSConcreteGlobalBlock", "_NSConcreteGlobalBlock")]
    if not blocks:
        errors.append("missing global block fixture")
    else:
        for index, block in enumerate(blocks):
            check_reference("global_block_" + str(index), [block], 0x6AE1)
    return {"compatible": not errors, "cpu_subtype": hex(subtype),
            "checks": checks, "errors": errors,
            "scope": "static ObjC superclass/global-block PAC schemas; not runtime or injection validation"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("object", type=Path)
    parser.add_argument("--json", type=Path)
    arguments = parser.parse_args()
    try:
        result = inspect_object(arguments.object.read_bytes())
    except (ValueError, UnicodeError, struct.error, OSError) as error:
        result = {"compatible": False, "errors": [str(error)]}
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if arguments.json:
        arguments.json.parent.mkdir(parents=True, exist_ok=True)
        arguments.json.write_text(text + "\n")
    print(text)
    return 0 if result["compatible"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
