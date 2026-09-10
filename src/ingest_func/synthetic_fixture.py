"""A fixed, deterministic PDF. No caller-supplied text, file paths, or bytes."""


def fixture_pdf() -> bytes:
    lines = (
        "Fun with Foundry - synthetic accelerator fixture v1",
        "Project Cedar is a fictional internal knowledge assistant.",
        "The fictional launch date is 15 October 2026.",
        "The fictional project owner is Morgan Example.",
        "The retention period for Project Cedar documents is 30 days.",
    )
    stream = b"BT /F1 12 Tf 50 750 Td 18 TL\n"
    stream += b"\n".join(f"({line}) Tj T*".encode("ascii") for line in lines) + b"\nET\n"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        f"<< /Length {len(stream)} >>\nstream\n".encode("ascii") + stream + b"endstream",
    ]
    result = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for number, body in enumerate(objects, 1):
        offsets.append(len(result))
        result.extend(f"{number} 0 obj\n".encode("ascii") + body + b"\nendobj\n")
    xref = len(result)
    result.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode("ascii"))
    for offset in offsets[1:]:
        result.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    result.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("ascii"))
    return bytes(result)
