"""Files on disk: page snapshots now, imported note images later."""
import base64
import re
from pathlib import Path

STORAGE_DIR = Path(__file__).resolve().parents[2] / "storage"
PAGES_DIR = STORAGE_DIR / "pages"
PAGES_DIR.mkdir(parents=True, exist_ok=True)

MAX_IMAGE_BYTES = 8 * 1024 * 1024
_DATA_URL = re.compile(r"^data:image/(png|jpeg|jpg|webp);base64,", re.I)
_EXTS = ("jpg", "png", "webp")


def decode_data_url(data_url: str) -> tuple[bytes, str]:
    m = _DATA_URL.match(data_url)
    if not m:
        raise ValueError("image must be a base64 data URL (png, jpeg or webp)")
    try:
        raw = base64.b64decode(data_url[m.end():], validate=True)
    except Exception:
        raise ValueError("image is not valid base64")
    if len(raw) > MAX_IMAGE_BYTES:
        raise ValueError("image is too large (max 8 MB)")
    ext = m.group(1).lower()
    return raw, "jpg" if ext == "jpeg" else ext


def find_page_image(page_id: int) -> Path | None:
    for ext in _EXTS:
        p = PAGES_DIR / f"{page_id}.{ext}"
        if p.exists():
            return p
    return None


def delete_page_image(page_id: int) -> None:
    for ext in _EXTS:
        (PAGES_DIR / f"{page_id}.{ext}").unlink(missing_ok=True)


def save_page_image(page_id: int, data_url: str) -> Path:
    raw, ext = decode_data_url(data_url)
    delete_page_image(page_id)
    path = PAGES_DIR / f"{page_id}.{ext}"
    path.write_bytes(raw)
    return path
