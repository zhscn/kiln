#!/usr/bin/env python3
"""Count normalized LIR code separately from packet storage and literals."""
import argparse
import json
import mmap
from pathlib import Path
import struct


def lir_stats(path):
    with Path(path).open('rb') as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        if data[:8] != b'KILNLIR\0':
            raise ValueError(f'{path}: expected a binary LIR packet')
        major, _, language = struct.unpack_from('<III', data, 8)
        if major != 1 or language != 2:
            raise ValueError(f'{path}: unsupported packet version or payload')
        records, edges, strings, root = struct.unpack_from('<IIII', data, 40)
        edge_start = 64 + 16 * records
        string_start = edge_start + 4 * edges
        if string_start + strings != len(data):
            raise ValueError(f'{path}: inconsistent packet lengths')

        def record(index):
            return struct.unpack_from('<IIQ', data, 64 + 16 * index)

        def children(index):
            tag, offset, count = record(index)
            if tag != 3:
                return ()
            return struct.unpack_from(f'<{count}I', data, edge_start + 4 * offset)

        def symbol(index):
            tag, offset, length = record(index)
            return data[string_start + offset:string_start + offset + length] if tag == 1 else None

        result = dict(functions=0, blocks=0, jump_only_blocks=0, variables=0, statements=0,
                      sets=0, polls=0, mv_saves=0, mv_restores=0, mv_moves=0, mv_counts=0,
                      mv_primary_refs=0, constants=0, record_bytes=16 * records,
                      edge_bytes=4 * edges, string_bytes=strings)
        for index in children(root):
            parts = children(index)
            if not parts:
                continue
            head = symbol(parts[0])
            if head == b'constants':
                result['constants'] += len(parts) - 1
            elif head == b'function':
                result['functions'] += 1
                for part in parts[2:]:
                    fields = children(part)
                    if not fields:
                        continue
                    name = symbol(fields[0])
                    if name == b'vars':
                        result['variables'] += len(fields) - 1
                    elif name == b'block':
                        result['blocks'] += 1
                        result['statements'] += len(fields) - 2
                        for statement in fields[2:]:
                            operation = children(statement)
                            if operation:
                                opcode = symbol(operation[0])
                                result['jump_only_blocks'] += len(fields) == 3 and opcode == b'jump'
                                if opcode == b'set':
                                    result['sets'] += 1
                                    expression = children(operation[2])
                                    if expression:
                                        kind = symbol(expression[0])
                                        result['mv_counts'] += kind == b'mv-count'
                                        if kind == b'mv-ref':
                                            tag, _, slot = record(expression[2])
                                            result['mv_primary_refs'] += tag == 0 and slot == 0
                                result['polls'] += opcode == b'poll'
                                result['mv_saves'] += opcode == b'mv-save'
                                result['mv_restores'] += opcode == b'mv-restore'
                                result['mv_moves'] += opcode == b'mv-move'
        return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', type=Path, nargs='+')
    args = parser.parse_args()
    print(json.dumps({str(path): lir_stats(path) for path in args.files}, indent=2))
