#!/usr/bin/env python3
"""Rewrite Pillow's positional `static PyTypeObject` initializers to DESIGNATED
initializers, in place.

Why: the wasthon bridge's PyTypeObject (src/wasthon.h) deliberately reorders its
fields (tp_free@4, tp_dict@8, tp_name@12, tp_basicsize/tp_dealloc/tp_flags/
tp_getset appended at the end) and relies on C code using *designated*
initializers (`.tp_name = ...`), the way numpy/pygame do — field order then does
not matter. Pillow, like uarray, uses classic *positional* initializers in
CPython field order, so every value lands in the wrong bridge slot: the type
name reads empty, the getsets are lost, and `ImagingCore` instances have no
`.mode`/`.size`. Converting the initializers to designated form makes the
compiler place each value into the bridge field of the same name.

Each Pillow initializer annotates every slot with a `/*tp_xxx*/` trailing
comment, so the conversion is driven entirely by those annotations — no reliance
on a hard-coded field order.

Usage: pil_designate.py <file.c> [<file.c> ...]
"""
import re
import sys

BLOCK = re.compile(r'(static\s+PyTypeObject\s+\w+\s*=\s*\{)(.*?)(\n\};)', re.S)


def convert_body(body: str) -> str:
    # Drop the header macro; it is re-emitted verbatim (it fills ob_refcnt/
    # tp_free positionally, then designated fields follow — legal C, and exactly
    # what numpy/pygame do against this same bridge header).
    body = re.sub(r'PyVarObject_HEAD_INIT\([^)]*\)', '', body, count=1)
    # Split on /* ... */ comments: [text, comment, text, comment, ...]. The text
    # chunk before each `tp_xxx` comment is that field's value.
    parts = re.split(r'/\*(.*?)\*/', body, flags=re.S)
    fields = []
    for i in range(len(parts) // 2):
        value = parts[2 * i].strip().rstrip(',').strip()
        field = parts[2 * i + 1].strip()
        if not field.startswith('tp_'):
            continue                      # bare "/* methods */" separators
        if not value or value == '0':
            continue                      # zero slots are implicit
        fields.append(f'    .{field} = {value},')
    return '\n    PyVarObject_HEAD_INIT(NULL, 0)\n' + '\n'.join(fields) + '\n'


def convert(text: str) -> tuple[str, int]:
    n = 0

    def repl(m):
        nonlocal n
        head, body, tail = m.group(1), m.group(2), m.group(3)
        if '.tp_name' in body:            # already designated — idempotent
            return m.group(0)
        n += 1
        return head + convert_body(body) + tail

    return BLOCK.sub(repl, text), n


def main(argv):
    total = 0
    for path in argv[1:]:
        with open(path, encoding='utf-8') as f:
            src = f.read()
        out, n = convert(src)
        if n:
            with open(path, 'w', encoding='utf-8') as f:
                f.write(out)
        total += n
        print(f'{path}: {n} PyTypeObject(s) -> designated')
    print(f'total: {total}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
