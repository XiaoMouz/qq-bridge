"""QQ 备份 protobuf wire 解码；64 位整数留在 Python，不经过浮点数。"""
from dataclasses import dataclass

class ProtoError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class Field:
    number: int
    wire: int
    value: int | bytes


def _varint(data: bytes, pos: int) -> tuple[int, int]:
    value = 0
    for shift in range(0, 70, 7):
        if pos >= len(data):
            raise ProtoError("truncated varint")
        byte = data[pos]
        pos += 1
        value |= (byte & 127) << shift
        if byte < 128:
            if value > (1 << 64) - 1:
                raise ProtoError("oversized varint")
            return value, pos
    raise ProtoError("oversized varint")


class Fields(list):
    __slots__=('indexed',)
    def __init__(self):super().__init__();self.indexed=None
    def lookup(self,number):
        if self.indexed is None:
            index={}
            for field in self:index.setdefault(field.number,[]).append(field)
            self.indexed=index
        return self.indexed.get(number,())


def parse_fields(blob: bytes | memoryview) -> list[Field]:
    data = bytes(blob)
    fields = Fields()
    pos = 0
    while pos < len(data):
        tag, pos = _varint(data, pos)
        number, wire = tag >> 3, tag & 7
        if not 0 < number < (1 << 29):
            raise ProtoError("invalid field number")
        if wire == 0:
            value, pos = _varint(data, pos)
        elif wire in (1, 5):
            end = pos + (8 if wire == 1 else 4)
            if end > len(data):
                raise ProtoError("truncated fixed field")
            value = int.from_bytes(data[pos:end], "little")
            pos = end
        elif wire == 2:
            length, pos = _varint(data, pos)
            end = pos + length
            if end > len(data):
                raise ProtoError("truncated bytes field")
            value = data[pos:end]
            pos = end
        else:
            raise ProtoError(f"unsupported wire type {wire}")
        fields.append(Field(number, wire, value))
    return fields


def values(fields: list[Field], number: int, wire: int | None = None):
    source=fields.lookup(number) if isinstance(fields,Fields) else fields
    return [f.value for f in source if f.number == number and (wire is None or f.wire == wire)]


def first(fields, number):
    return next(iter(values(fields, number)), None)


def text(value):
    if not isinstance(value, bytes):
        return str(value) if value is not None else None
    try:
        return value.decode('utf-8')
    except UnicodeDecodeError:
        return None
