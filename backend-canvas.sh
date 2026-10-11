#!/usr/bin/env bash
# Patch 3: import college notes (PDF, scanned PDF, photos, PPTX, DOCX, TXT/MD)
# as canvas pages the student can write on top of.
#   POST /api/projects/{id}/import   (multipart, field "files", several allowed)
# Requires patches 1 and 2. Run from the project root:
#   bash add_import_backend.sh
# Then install the libraries into your conda env:
#   pip install pymupdf python-pptx python-docx
# Safe to re-run. Rewrites: services/storage.py, services/notes.py,
# routers/pages.py, main.py.
set -e

if [ ! -f backend/app/services/notes.py ] || [ ! -f backend/app/routers/study.py ]; then
  echo "!! Patches 1 and 2 are not installed here. Run add_canvas_backend.sh and add_ai_backend.sh first."
  exit 1
fi

mkdir -p backend/app/routers backend/app/services backend/storage

# ------------------------------------------------------------ requirements
touch backend/requirements.txt
for pkg in pymupdf python-pptx python-docx; do
  grep -qi "^${pkg}\b" backend/requirements.txt || echo "$pkg" >> backend/requirements.txt
done

# ---------------------------------------------------------------- storage
cat > backend/app/services/storage.py <<'EOF'
"""Files on disk: page snapshots, imported backgrounds, imported source text."""
import base64
import re
import uuid
from pathlib import Path

STORAGE_DIR = Path(__file__).resolve().parents[2] / "storage"
PAGES_DIR = STORAGE_DIR / "pages"
IMPORTS_DIR = STORAGE_DIR / "imports"
SOURCES_DIR = STORAGE_DIR / "sources"
for _d in (PAGES_DIR, IMPORTS_DIR, SOURCES_DIR):
    _d.mkdir(parents=True, exist_ok=True)

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


def _clear_page_images(page_id: int) -> None:
    for ext in _EXTS:
        (PAGES_DIR / f"{page_id}.{ext}").unlink(missing_ok=True)


def save_page_image_bytes(page_id: int, raw: bytes, ext: str = "jpg") -> Path:
    _clear_page_images(page_id)
    path = PAGES_DIR / f"{page_id}.{ext}"
    path.write_bytes(raw)
    return path


def save_page_image(page_id: int, data_url: str) -> Path:
    raw, ext = decode_data_url(data_url)
    return save_page_image_bytes(page_id, raw, ext)


def delete_page_image(page_id: int) -> None:
    """Called whenever a page is deleted: removes its snapshot AND source text."""
    _clear_page_images(page_id)
    (SOURCES_DIR / f"{page_id}.txt").unlink(missing_ok=True)


# ---- imported files -------------------------------------------------------
def save_import_image(raw: bytes, ext: str = "jpg") -> str:
    """Stores an imported page background; returns its URL path (/files/...)."""
    name = f"{uuid.uuid4().hex}.{ext}"
    (IMPORTS_DIR / name).write_bytes(raw)
    return f"/files/imports/{name}"


def write_page_source(page_id: int, text: str) -> None:
    """Text that came from the imported file (and is NOT drawn as text boxes)."""
    path = SOURCES_DIR / f"{page_id}.txt"
    if text.strip():
        path.write_text(text, encoding="utf-8")
    else:
        path.unlink(missing_ok=True)


def read_page_source(page_id: int) -> str:
    path = SOURCES_DIR / f"{page_id}.txt"
    return path.read_text(encoding="utf-8") if path.exists() else ""
EOF

# ------------------------------------------------------------------- notes
cat > backend/app/services/notes.py <<'EOF'
"""Turns pages into grounded context for the AI, and keeps transcripts fresh."""
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

from fastapi import HTTPException
from sqlmodel import Session, select

from app.canvas_models import Page, Project
from app.db import engine
from app.services import ai
from app.services.storage import decode_data_url, find_page_image, read_page_source
from app.services.transcript import text_from_content

MAX_CONTEXT_CHARS = 48_000


def has_strokes(content: dict) -> bool:
    return any(
        o.get("type") == "stroke" and o.get("tool") != "eraser"
        for o in (content or {}).get("objects", [])
    )


def needs_vision(page: Page) -> bool:
    """Handwriting/drawings, or an imported image page with no extracted text,
    can only be read by the vision model (from the saved page snapshot)."""
    if not find_page_image(page.id):
        return False
    content = page.content or {}
    if has_strokes(content):
        return True
    return bool(content.get("background")) and not read_page_source(page.id)


def text_transcript(page: Page) -> str:
    """Exact text: extracted source text + typed text boxes (no AI needed)."""
    parts = [read_page_source(page.id).strip(), text_from_content(page.content or {})]
    return "\n\n".join(p for p in parts if p)


def apply_text_transcript(page: Page) -> None:
    new = text_transcript(page)
    if new or not (page.content or {}).get("background"):
        page.transcript = new
    page.transcript_status = "ready"


def transcribe_page(session: Session, page: Page) -> None:
    """Refresh page.transcript (vision model when needed, otherwise exact text)."""
    if needs_vision(page):
        img = find_page_image(page.id)
        try:
            text = ai.transcribe_image(img.read_bytes(), img.suffix.lstrip("."))
            page.transcript = text or text_transcript(page)
            page.transcript_status = "ready"
        except ai.AIError:
            page.transcript = text_transcript(page) or page.transcript
            page.transcript_status = "failed"
    else:
        apply_text_transcript(page)
    session.add(page)
    session.commit()
    session.refresh(page)


def transcribe_pages_bg(page_ids: list[int], workers: int = 4) -> None:
    """Background job: transcribe many pending pages in parallel (own sessions)."""

    def one(pid: int) -> None:
        with Session(engine) as session:
            page = session.get(Page, pid)
            if page and page.transcript_status == "pending":
                transcribe_page(session, page)

    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(one, page_ids))


def ensure_fresh(session: Session, pages: list[Page]) -> None:
    for page in pages:
        if page.transcript_status in ("pending", "failed"):
            transcribe_page(session, page)


@dataclass
class NotesContext:
    pages: list[Page]
    text: str
    focus: str | None = None
    truncated: bool = False
    warning: str | None = None
    titles: dict[int, str] = field(default_factory=dict)

    @property
    def empty(self) -> bool:
        return not self.text.strip() and not self.focus

    @property
    def page_ids(self) -> set[int]:
        return {p.id for p in self.pages}

    @property
    def plain(self) -> str:
        """Raw notes text without the page labels (used when refining whole pages)."""
        return "\n\n".join(p.transcript.strip() for p in self.pages if (p.transcript or "").strip())


def load_scope(session: Session, req) -> NotesContext:
    """req needs: project_id, scope ("page"|"project"), page_id, selection."""
    if not session.get(Project, req.project_id):
        raise HTTPException(404, "Project not found")

    all_pages = list(
        session.exec(
            select(Page).where(Page.project_id == req.project_id).order_by(Page.position)
        ).all()
    )
    if req.scope == "page":
        if req.page_id is None:
            raise HTTPException(400, "page_id is required when scope is 'page'")
        pages = [p for p in all_pages if p.id == req.page_id]
        if not pages:
            raise HTTPException(400, "That page does not belong to this project")
    else:
        pages = all_pages

    ensure_fresh(session, pages)

    chunks, total, truncated = [], 0, False
    for p in pages:
        body = (p.transcript or "").strip()
        if not body:
            continue
        chunk = f"### Page {p.position + 1}: {p.title} [id={p.id}]\n{body}\n"
        if total + len(chunk) > MAX_CONTEXT_CHARS:
            room = MAX_CONTEXT_CHARS - total
            if room > 500:
                chunks.append(chunk[:room] + "\n[...cut: notes too long]")
            truncated = True
            break
        chunks.append(chunk)
        total += len(chunk)

    focus = None
    sel = getattr(req, "selection", None)
    if sel and sel.text and sel.text.strip():
        focus = sel.text.strip()
    elif sel and sel.image:
        try:
            raw, ext = decode_data_url(sel.image)
        except ValueError as e:
            raise HTTPException(400, str(e))
        focus = ai.transcribe_image(raw, ext) or None

    warning = None
    if any(p.transcript_status == "failed" for p in pages):
        warning = "Some handwritten pages could not be read, so answers may be incomplete."

    return NotesContext(
        pages=pages,
        text="\n".join(chunks),
        focus=focus,
        truncated=truncated,
        warning=warning,
        titles={p.id: p.title for p in all_pages},
    )
EOF

# -------------------------------------------------------------- pages router
cat > backend/app/routers/pages.py <<'EOF'
import time

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from fastapi.responses import FileResponse
from sqlmodel import Session, select

from app.canvas_models import Page, Project, utcnow
from app.db import engine, get_session
from app.schemas import PageRead, PageRename, PageSummary, PageUpdate
from app.services import notes
from app.services.storage import delete_page_image, find_page_image, save_page_image

router = APIRouter()

PREFETCH_DELAY = 8  # seconds of quiet before transcribing in the background
_latest: dict[int, int] = {}


def get_page_or_404(session: Session, page_id: int) -> Page:
    page = session.get(Page, page_id)
    if not page:
        raise HTTPException(404, "Page not found")
    return page


def touch_project(session: Session, project_id: int) -> None:
    project = session.get(Project, project_id)
    if project:
        project.updated_at = utcnow()
        session.add(project)


def _prefetch(page_id: int, token: int) -> None:
    """Debounced: only the most recent save of a page actually transcribes."""
    time.sleep(PREFETCH_DELAY)
    if _latest.get(page_id) != token:
        return
    with Session(engine) as session:
        page = session.get(Page, page_id)
        if page and page.transcript_status == "pending":
            notes.transcribe_page(session, page)


@router.get("/{page_id}", response_model=PageRead)
def get_page(page_id: int, session: Session = Depends(get_session)):
    return PageRead.model_validate(get_page_or_404(session, page_id))


@router.put("/{page_id}", response_model=PageSummary)
def save_page(
    page_id: int,
    body: PageUpdate,
    background: BackgroundTasks,
    session: Session = Depends(get_session),
):
    page = get_page_or_404(session, page_id)
    if body.image:
        try:
            save_page_image(page.id, body.image)
        except ValueError as e:
            raise HTTPException(400, str(e))

    page.content = body.content.model_dump(mode="json")  # new dict -> change detected

    if notes.needs_vision(page):
        # handwriting / scanned background: read it with the vision model.
        # AI endpoints refresh pending pages on demand; this prefetches in the
        # background once the student pauses.
        page.transcript_status = "pending"
        _latest[page.id] = _latest.get(page.id, 0) + 1
        background.add_task(_prefetch, page.id, _latest[page.id])
    else:
        notes.apply_text_transcript(page)

    session.add(page)
    touch_project(session, page.project_id)
    session.commit()
    session.refresh(page)
    return PageSummary.model_validate(page)


@router.patch("/{page_id}", response_model=PageSummary)
def rename_page(
    page_id: int, body: PageRename, session: Session = Depends(get_session)
):
    page = get_page_or_404(session, page_id)
    page.title = body.title.strip()
    session.add(page)
    touch_project(session, page.project_id)
    session.commit()
    session.refresh(page)
    return PageSummary.model_validate(page)


@router.delete("/{page_id}")
def delete_page(page_id: int, session: Session = Depends(get_session)):
    page = get_page_or_404(session, page_id)
    siblings = session.exec(
        select(Page).where(Page.project_id == page.project_id).order_by(Page.position)
    ).all()
    if len(siblings) <= 1:
        raise HTTPException(400, "A project needs at least one page")
    delete_page_image(page.id)
    session.delete(page)
    for index, sibling in enumerate(s for s in siblings if s.id != page.id):
        sibling.position = index
        session.add(sibling)
    touch_project(session, page.project_id)
    session.commit()
    return {"ok": True}


@router.get("/{page_id}/image")
def get_page_image(page_id: int, session: Session = Depends(get_session)):
    get_page_or_404(session, page_id)
    path = find_page_image(page_id)
    if not path:
        raise HTTPException(404, "No snapshot saved for this page yet")
    return FileResponse(path, headers={"Cache-Control": "no-cache"})
EOF

# --------------------------------------------------------------- importer
cat > backend/app/services/importer.py <<'EOF'
"""Turns uploaded files into page drafts (canvas content + extracted text).

PDF / photos   -> one page per PDF page; the page image is the background.
                  Typed PDF pages keep their extracted text; scanned or
                  handwritten pages are read later by the vision model.
PPTX           -> converted to PDF with LibreOffice when installed (slides look
                  exactly like the original); otherwise one text-only page per
                  slide (title + bullets as text boxes, speaker notes kept).
DOCX / TXT / MD -> text laid out on portrait pages as text boxes.
"""
import io
import os
import shutil
import subprocess
import tempfile
import textwrap
import uuid
from dataclasses import dataclass, field
from pathlib import Path

PAGE_W = 1200
MARGIN = 60
TEXT_MIN_CHARS = 40          # fewer extracted chars -> treat the page as an image
DOC_PAGE_H = 1600
IMG_EXTS = {".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff"}
FONT = {"h1": 40, "h2": 32, "body": 26, "bullet": 26}


class ImportProblem(Exception):
    pass


@dataclass
class PageDraft:
    title: str
    height: int
    objects: list = field(default_factory=list)
    background: bytes | None = None   # JPEG bytes of the page image
    source_text: str = ""             # text NOT already present as text boxes
    vision: bool = False              # needs the vision model to read it


# ------------------------------------------------------------------ helpers
def _fitz():
    try:
        import pymupdf as fitz
    except ImportError:
        try:
            import fitz  # older PyMuPDF
        except ImportError:
            raise ImportProblem("PDF/photo import needs PyMuPDF. Run: pip install pymupdf")
    return fitz


def _text_obj(x: float, y: float, text: str, size: int) -> dict:
    return {
        "id": uuid.uuid4().hex[:8],
        "type": "text",
        "x": x,
        "y": round(y),
        "text": text,
        "fontSize": size,
        "color": "#111111",
    }


def layout_blocks(blocks, paginate_height: int | None = None, min_height: int = 675):
    """blocks: [(kind, text, level)] with kind in h1|h2|body|bullet.
    Returns [(objects, text, height)]. Without paginate_height everything goes
    on one page that grows; with it, text flows across pages."""

    def new_page():
        return {"objects": [], "text": [], "y": float(MARGIN)}

    pages = [new_page()]
    for kind, text, level in blocks:
        text = (text or "").strip()
        if not text:
            continue
        fs = FONT[kind]
        lh = fs * 1.35
        indent = 0 if kind in ("h1", "h2", "body") else 28 + 28 * level
        x = MARGIN + indent
        chars = max(20, int((PAGE_W - MARGIN - x) / (fs * 0.52)))
        prefix = "\u2022 " if kind == "bullet" else ""
        lines = textwrap.wrap(
            prefix + " ".join(text.split()), chars, subsequent_indent="  " if prefix else ""
        ) or [""]
        if pages[-1]["objects"]:
            pages[-1]["y"] += 22 if kind in ("h1", "h2") else 10
        while lines:
            page = pages[-1]
            if paginate_height:
                room = int((paginate_height - MARGIN - page["y"]) // lh)
                if room < 1 and page["objects"]:
                    pages.append(new_page())
                    continue
                take = max(1, room)
            else:
                take = len(lines)
            chunk, lines = lines[:take], lines[take:]
            page["objects"].append(_text_obj(x, page["y"], "\n".join(chunk), fs))
            page["text"].append("\n".join(chunk))
            page["y"] += len(chunk) * lh
            if lines:
                pages.append(new_page())

    out = []
    for p in pages:
        if not p["objects"] and len(pages) > 1:
            continue
        height = paginate_height or max(min_height, int(p["y"] + MARGIN))
        out.append((p["objects"], "\n".join(p["text"]), height))
    return out


# ---------------------------------------------------------------------- PDF
def _pdf(data: bytes, stem: str, limit: int):
    fitz = _fitz()
    try:
        doc = fitz.open(stream=data, filetype="pdf")
    except Exception:
        raise ImportProblem("could not open this PDF (damaged?)")
    if doc.needs_pass:
        raise ImportProblem("this PDF is password protected")

    drafts: list[PageDraft] = []
    warnings: list[str] = []
    total = doc.page_count
    for i in range(min(total, limit)):
        page = doc[i]
        zoom = PAGE_W / max(page.rect.width, 1)
        pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False)
        text = page.get_text().strip()
        title = stem if total == 1 else f"{stem} - p{i + 1}"
        drafts.append(
            PageDraft(
                title=title[:200],
                height=max(300, min(pix.height, 4000)),
                background=pix.tobytes("jpeg"),
                source_text=text if len(text) >= TEXT_MIN_CHARS else "",
                vision=len(text) < TEXT_MIN_CHARS,
            )
        )
    if total > limit:
        warnings.append(f"{stem}: only the first {limit} of {total} pages were imported (page limit).")
    doc.close()
    return drafts, warnings


def _image(data: bytes, stem: str, ext: str, limit: int):
    fitz = _fitz()
    try:
        img_doc = fitz.open(stream=data, filetype=ext.lstrip("."))
        pdf_bytes = img_doc.convert_to_pdf()
    except Exception:
        raise ImportProblem("could not read this image (try PNG or JPEG)")
    return _pdf(pdf_bytes, stem, limit)


# --------------------------------------------------------------------- PPTX
def find_soffice() -> str | None:
    for name in ("soffice", "libreoffice"):
        found = shutil.which(name)
        if found:
            return found
    for p in (
        r"C:\Program Files\LibreOffice\program\soffice.exe",
        r"C:\Program Files (x86)\LibreOffice\program\soffice.exe",
        "/Applications/LibreOffice.app/Contents/MacOS/soffice",
    ):
        if os.path.exists(p):
            return p
    return None


def _pptx_to_pdf(data: bytes) -> bytes | None:
    soffice = find_soffice()
    if not soffice:
        return None
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "slides.pptx"
        src.write_bytes(data)
        try:
            subprocess.run(
                [soffice, "--headless", "--convert-to", "pdf", "--outdir", tmp, str(src)],
                capture_output=True,
                timeout=180,
                check=False,
            )
        except (subprocess.TimeoutExpired, OSError):
            return None
        out = Path(tmp) / "slides.pdf"
        return out.read_bytes() if out.exists() else None


def _iter_shapes(shapes):
    from pptx.enum.shapes import MSO_SHAPE_TYPE

    for shape in shapes:
        if shape.shape_type == MSO_SHAPE_TYPE.GROUP:
            yield from _iter_shapes(shape.shapes)
        else:
            yield shape


def _pptx_text(data: bytes, stem: str, limit: int):
    try:
        from pptx import Presentation
    except ImportError:
        raise ImportProblem("PPTX import needs python-pptx. Run: pip install python-pptx")
    try:
        prs = Presentation(io.BytesIO(data))
    except Exception:
        raise ImportProblem("could not open this PPTX (damaged?)")

    ratio = (prs.slide_height / prs.slide_width) if prs.slide_width else 0.5625
    min_h = int(PAGE_W * ratio)
    slides = list(prs.slides)
    drafts: list[PageDraft] = []
    for n, slide in enumerate(slides[:limit], 1):
        title_shape = slide.shapes.title
        title_text = title_shape.text_frame.text.strip() if title_shape is not None and title_shape.has_text_frame else ""
        blocks = []
        if title_text:
            blocks.append(("h1", title_text, 0))
        shapes = sorted(
            _iter_shapes(slide.shapes),
            key=lambda s: (getattr(s, "top", None) or 0, getattr(s, "left", None) or 0),
        )
        for shape in shapes:
            if title_shape is not None and shape.shape_id == title_shape.shape_id:
                continue
            if shape.has_text_frame:
                for para in shape.text_frame.paragraphs:
                    t = "".join(r.text for r in para.runs).strip()
                    if t:
                        kind = "bullet" if shape.is_placeholder else "body"
                        blocks.append((kind, t, para.level or 0))
            elif getattr(shape, "has_table", False) and shape.has_table:
                for row in shape.table.rows:
                    cells = [c.text.strip() for c in row.cells if c.text.strip()]
                    if cells:
                        blocks.append(("body", " | ".join(cells), 0))
        notes = ""
        if slide.has_notes_slide and slide.notes_slide.notes_text_frame is not None:
            notes = slide.notes_slide.notes_text_frame.text.strip()
        pages = layout_blocks(blocks, paginate_height=None, min_height=min_h) or [([], "", min_h)]
        objs, _text, height = pages[0]
        drafts.append(
            PageDraft(
                title=(title_text[:60] or f"{stem} - slide {n}"),
                height=height,
                objects=objs,
                source_text=f"Speaker notes: {notes}" if notes else "",
            )
        )
    warnings = []
    if len(slides) > limit:
        warnings.append(f"{stem}: only the first {limit} of {len(slides)} slides were imported (page limit).")
    warnings.append(
        f"{stem}: imported as text (slide visuals/images are not included). "
        "For exact-looking slides, use PowerPoint > Save as PDF and import the PDF."
    )
    return drafts, warnings


def _pptx(data: bytes, stem: str, limit: int):
    pdf = _pptx_to_pdf(data)
    if pdf:
        try:
            return _pdf(pdf, stem, limit)
        except ImportProblem:
            pass
    return _pptx_text(data, stem, limit)


# --------------------------------------------------------------- DOCX / text
def _paged_text(blocks, stem: str, limit: int):
    pages = layout_blocks(blocks, paginate_height=DOC_PAGE_H)
    if not pages:
        raise ImportProblem("no text found in this file")
    drafts, warnings = [], []
    for i, (objs, _text, height) in enumerate(pages[:limit], 1):
        title = stem if len(pages) == 1 else f"{stem} ({i})"
        drafts.append(PageDraft(title=title[:200], height=height, objects=objs))
    if len(pages) > limit:
        warnings.append(f"{stem}: only the first {limit} of {len(pages)} pages were imported (page limit).")
    return drafts, warnings


def _docx(data: bytes, stem: str, limit: int):
    try:
        import docx
        from docx.table import Table
        from docx.text.paragraph import Paragraph
    except ImportError:
        raise ImportProblem("DOCX import needs python-docx. Run: pip install python-docx")
    try:
        document = docx.Document(io.BytesIO(data))
    except Exception:
        raise ImportProblem("could not open this DOCX (damaged?)")

    blocks = []
    for el in document.element.body.iterchildren():
        tag = el.tag.rsplit("}", 1)[-1]
        if tag == "p":
            p = Paragraph(el, document)
            text = p.text.strip()
            if not text:
                continue
            style = (p.style.name if p.style is not None else "") or ""
            if style == "Title" or style == "Heading 1":
                blocks.append(("h1", text, 0))
            elif style.startswith("Heading"):
                blocks.append(("h2", text, 0))
            elif "List" in style:
                blocks.append(("bullet", text, 0))
            else:
                blocks.append(("body", text, 0))
        elif tag == "tbl":
            for row in Table(el, document).rows:
                cells = [c.text.strip() for c in row.cells if c.text.strip()]
                if cells:
                    blocks.append(("body", " | ".join(cells), 0))
    return _paged_text(blocks, stem, limit)


def _plain(data: bytes, stem: str, limit: int):
    blocks = []
    for raw in data.decode("utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("## "):
            blocks.append(("h2", line[3:], 0))
        elif line.startswith("#"):
            blocks.append(("h1", line.lstrip("#").strip(), 0))
        elif line[:2] in ("- ", "* "):
            blocks.append(("bullet", line[2:], 0))
        else:
            blocks.append(("body", line, 0))
    return _paged_text(blocks, stem, limit)


# ----------------------------------------------------------------- dispatch
def import_file(filename: str, data: bytes, limit: int):
    """Returns (drafts, warnings). Raises ImportProblem for a file we can't use."""
    ext = Path(filename).suffix.lower()
    stem = Path(filename).stem.strip()[:50] or "Imported"
    if ext == ".pdf":
        return _pdf(data, stem, limit)
    if ext in IMG_EXTS:
        return _image(data, stem, ext, limit)
    if ext == ".pptx":
        return _pptx(data, stem, limit)
    if ext == ".docx":
        return _docx(data, stem, limit)
    if ext in (".txt", ".md"):
        return _plain(data, stem, limit)
    if ext in (".ppt", ".doc"):
        raise ImportProblem("old .ppt/.doc files are not supported. Save as .pptx/.docx or export to PDF.")
    raise ImportProblem(f"unsupported file type '{ext or 'unknown'}' (use PDF, PPTX, DOCX, TXT, MD or an image)")
EOF

# ------------------------------------------------------------ import router
cat > backend/app/routers/imports.py <<'EOF'
from fastapi import APIRouter, BackgroundTasks, Depends, File, HTTPException, UploadFile
from sqlmodel import Session, func, select

from app.canvas_models import Page, utcnow
from app.db import get_session
from app.routers.projects import get_project_or_404, project_pages
from app.schemas import PageSummary
from app.services import importer, notes
from app.services.storage import (
    delete_page_image,
    save_import_image,
    save_page_image_bytes,
    write_page_source,
)

router = APIRouter()

MAX_FILE_BYTES = 40 * 1024 * 1024
MAX_PAGES_PER_IMPORT = 120


def _is_blank(page: Page) -> bool:
    content = page.content or {}
    return not content.get("objects") and not content.get("background") and not (page.transcript or "").strip()


@router.post("/{project_id}/import")
def import_files(
    project_id: int,
    background: BackgroundTasks,
    files: list[UploadFile] = File(...),
    replace_blank: bool = True,
    session: Session = Depends(get_session),
):
    """Import PDF / PPTX / DOCX / TXT / MD / images as new pages at the end of the
    project. If the project only has one empty page and replace_blank is true,
    that empty page is removed (so the student doesn't keep a stray blank page)."""
    project = get_project_or_404(session, project_id)

    drafts: list[importer.PageDraft] = []
    warnings: list[str] = []
    remaining = MAX_PAGES_PER_IMPORT
    for upload in files:
        name = upload.filename or "file"
        data = upload.file.read()
        if len(data) > MAX_FILE_BYTES:
            warnings.append(f"{name}: file is larger than {MAX_FILE_BYTES // (1024 * 1024)} MB, skipped.")
            continue
        try:
            file_drafts, file_warnings = importer.import_file(name, data, remaining)
        except importer.ImportProblem as e:
            warnings.append(f"{name}: {e}")
            continue
        drafts += file_drafts
        warnings += file_warnings
        remaining -= len(file_drafts)
        if remaining <= 0:
            warnings.append("Page limit reached for this import; remaining files were skipped.")
            break

    if not drafts:
        raise HTTPException(400, " ".join(warnings) or "Nothing could be imported.")

    existing = project_pages(session, project_id)
    if replace_blank and len(existing) == 1 and _is_blank(existing[0]):
        delete_page_image(existing[0].id)
        session.delete(existing[0])
        session.commit()
        existing = []
    position = (max((p.position for p in existing), default=-1)) + 1

    created: list[Page] = []
    for d in drafts:
        bg_url = save_import_image(d.background) if d.background else None
        page = Page(
            project_id=project_id,
            title=d.title,
            position=position,
            content={"width": 1200, "height": d.height, "background": bg_url, "objects": d.objects},
        )
        session.add(page)
        session.commit()
        session.refresh(page)
        if d.background:
            save_page_image_bytes(page.id, d.background)  # snapshot used for vision
        write_page_source(page.id, d.source_text)
        if d.vision:
            page.transcript, page.transcript_status = "", "pending"
        else:
            notes.apply_text_transcript(page)
        session.add(page)
        session.commit()
        session.refresh(page)
        created.append(page)
        position += 1

    project.updated_at = utcnow()
    session.add(project)
    session.commit()

    pending = [p.id for p in created if p.transcript_status == "pending"]
    if pending:
        background.add_task(notes.transcribe_pages_bg, pending)

    return {"pages": [PageSummary.model_validate(p) for p in created], "warnings": warnings}
EOF

# --------------------------------------------------------------------- main
cat > backend/app/main.py <<'EOF'
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app import ai_models  # noqa: F401  (registers quiz tables)
from app.core.config import settings
from app.db import init_db
from app.routers import chat, health, imports, items, pages, projects, study
from app.services.storage import STORAGE_DIR


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    yield


app = FastAPI(title=settings.app_name, lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health.router, prefix="/api", tags=["health"])
app.include_router(items.router, prefix="/api/items", tags=["items"])
app.include_router(chat.router, prefix="/api/chat", tags=["chat"])
app.include_router(projects.router, prefix="/api/projects", tags=["projects"])
app.include_router(imports.router, prefix="/api/projects", tags=["import"])
app.include_router(pages.router, prefix="/api/pages", tags=["pages"])
app.include_router(study.router, prefix="/api/ai", tags=["ai"])
app.include_router(study.insights_router, prefix="/api/projects", tags=["ai"])

# uploaded / imported files, served at /files/...
app.mount("/files", StaticFiles(directory=STORAGE_DIR), name="files")
EOF

echo ""
echo "Done. Patch 3 (import) installed."
echo "  1. Install the libraries in your conda env:"
echo "       pip install pymupdf python-pptx python-docx"
echo "  2. Restart the backend task."
echo "  3. Try POST /api/projects/{id}/import at http://localhost:8000/docs (choose files)."
echo "  Optional: install LibreOffice so .pptx slides keep their exact look;"
echo "  without it slides are imported as text pages."