#!/usr/bin/env bash
# Patch 1: projects + pages CRUD for the Interactive AI Learning Canvas.
# Run from the project root (folder containing backend/ and frontend/):
#   bash add_canvas_backend.sh
# Safe to re-run. Backs up backend/app/main.py to main.py.bak (first run only).
set -e

if [ ! -f backend/app/main.py ]; then
  echo "!! Run this from the project root (backend/app/main.py not found here)."
  exit 1
fi
[ -f backend/app/main.py.bak ] || cp backend/app/main.py backend/app/main.py.bak

mkdir -p backend/app/routers backend/app/services backend/storage

# ------------------------------------------------------------- db models
cat > backend/app/canvas_models.py <<'EOF'
from datetime import datetime, timezone

from sqlalchemy import Column, JSON
from sqlmodel import Field, SQLModel


def utcnow() -> datetime:
    # timezone-aware UTC (newer SQLModel requires it); API output ends with "Z"
    return datetime.now(timezone.utc)


def new_page_content() -> dict:
    return {"width": 1200, "height": 800, "background": None, "objects": []}


class Project(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    name: str
    created_at: datetime = Field(default_factory=utcnow)
    updated_at: datetime = Field(default_factory=utcnow)


class Page(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    project_id: int = Field(foreign_key="project.id", index=True)
    title: str = "Untitled page"
    position: int = 0
    content: dict = Field(default_factory=new_page_content, sa_column=Column(JSON))
    transcript: str = ""
    transcript_status: str = "ready"  # "pending" | "ready" | "failed"
EOF

# --------------------------------------------------------------- schemas
cat > backend/app/schemas.py <<'EOF'
from datetime import datetime, timezone
from typing import Annotated, Literal, Union

from pydantic import BaseModel, ConfigDict, Field, PlainSerializer


def _iso_utc(d: datetime) -> str:
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.isoformat().replace("+00:00", "Z")


UtcDatetime = Annotated[datetime, PlainSerializer(_iso_utc, return_type=str)]


# ---- canvas page content (what the frontend draws) ----------------------
class StrokeObject(BaseModel):
    model_config = ConfigDict(extra="allow")
    id: str
    type: Literal["stroke"]
    tool: Literal["pen", "highlighter", "eraser"] = "pen"
    color: str = "#000000"
    size: float = 2
    points: list[list[float]] = []


class TextObject(BaseModel):
    model_config = ConfigDict(extra="allow")
    id: str
    type: Literal["text"]
    x: float
    y: float
    text: str = ""
    fontSize: float = 24
    color: str = "#000000"


CanvasObject = Annotated[Union[StrokeObject, TextObject], Field(discriminator="type")]


class PageContent(BaseModel):
    model_config = ConfigDict(extra="allow")
    width: int = 1200
    height: int = 800
    background: str | None = None
    objects: list[CanvasObject] = Field(default_factory=list)


# ---- responses ----------------------------------------------------------
class ProjectRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    name: str
    created_at: UtcDatetime
    updated_at: UtcDatetime
    page_count: int = 0


class PageSummary(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    project_id: int
    title: str
    position: int
    transcript_status: str


class PageRead(PageSummary):
    content: PageContent
    transcript: str


class ProjectDetail(ProjectRead):
    pages: list[PageSummary]


# ---- requests -----------------------------------------------------------
class ProjectCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)


class ProjectUpdate(BaseModel):
    name: str = Field(min_length=1, max_length=200)


class PageCreate(BaseModel):
    title: str | None = Field(default=None, max_length=200)


class PageRename(BaseModel):
    title: str = Field(min_length=1, max_length=200)


class PageUpdate(BaseModel):
    content: PageContent
    image: str | None = None  # JPEG/PNG data URL of the composite page


class ReorderRequest(BaseModel):
    page_ids: list[int]
EOF

# -------------------------------------------------------------- services
cat > backend/app/services/storage.py <<'EOF'
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
EOF

cat > backend/app/services/transcript.py <<'EOF'
def text_from_content(content: dict) -> str:
    """Typed text boxes are already text. Handwriting is added by the
    vision-transcription step (next patch)."""
    texts = [
        o
        for o in content.get("objects", [])
        if o.get("type") == "text" and (o.get("text") or "").strip()
    ]
    texts.sort(key=lambda o: (round(o.get("y", 0) / 20), o.get("x", 0)))
    return "\n".join(o["text"].strip() for o in texts)
EOF

# --------------------------------------------------------------- routers
cat > backend/app/routers/projects.py <<'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session, func, select

from app.canvas_models import Page, Project, utcnow
from app.db import get_session
from app.schemas import (
    PageCreate,
    PageSummary,
    ProjectCreate,
    ProjectDetail,
    ProjectRead,
    ProjectUpdate,
    ReorderRequest,
)
from app.services.storage import delete_page_image

router = APIRouter()


def get_project_or_404(session: Session, project_id: int) -> Project:
    project = session.get(Project, project_id)
    if not project:
        raise HTTPException(404, "Project not found")
    return project


def project_pages(session: Session, project_id: int) -> list[Page]:
    return list(
        session.exec(
            select(Page).where(Page.project_id == project_id).order_by(Page.position)
        ).all()
    )


def to_read(project: Project, page_count: int) -> ProjectRead:
    return ProjectRead(
        id=project.id,
        name=project.name,
        created_at=project.created_at,
        updated_at=project.updated_at,
        page_count=page_count,
    )


def to_detail(session: Session, project: Project) -> ProjectDetail:
    pages = project_pages(session, project.id)
    return ProjectDetail(
        id=project.id,
        name=project.name,
        created_at=project.created_at,
        updated_at=project.updated_at,
        page_count=len(pages),
        pages=[PageSummary.model_validate(p) for p in pages],
    )


@router.get("", response_model=list[ProjectRead])
def list_projects(session: Session = Depends(get_session)):
    projects = session.exec(select(Project).order_by(Project.updated_at.desc())).all()
    counts = dict(
        session.exec(select(Page.project_id, func.count()).group_by(Page.project_id)).all()
    )
    return [to_read(p, counts.get(p.id, 0)) for p in projects]


@router.post("", response_model=ProjectDetail)
def create_project(body: ProjectCreate, session: Session = Depends(get_session)):
    project = Project(name=body.name.strip())
    session.add(project)
    session.commit()
    session.refresh(project)
    session.add(Page(project_id=project.id, title="Page 1", position=0))
    session.commit()
    return to_detail(session, project)


@router.get("/{project_id}", response_model=ProjectDetail)
def get_project(project_id: int, session: Session = Depends(get_session)):
    return to_detail(session, get_project_or_404(session, project_id))


@router.patch("/{project_id}", response_model=ProjectRead)
def rename_project(
    project_id: int, body: ProjectUpdate, session: Session = Depends(get_session)
):
    project = get_project_or_404(session, project_id)
    project.name = body.name.strip()
    project.updated_at = utcnow()
    session.add(project)
    session.commit()
    session.refresh(project)
    return to_read(project, len(project_pages(session, project.id)))


@router.delete("/{project_id}")
def delete_project(project_id: int, session: Session = Depends(get_session)):
    project = get_project_or_404(session, project_id)
    for page in project_pages(session, project_id):
        delete_page_image(page.id)
        session.delete(page)
    session.delete(project)
    session.commit()
    return {"ok": True}


@router.post("/{project_id}/pages", response_model=PageSummary)
def create_page(
    project_id: int, body: PageCreate, session: Session = Depends(get_session)
):
    project = get_project_or_404(session, project_id)
    last = session.exec(
        select(func.max(Page.position)).where(Page.project_id == project_id)
    ).one()
    position = 0 if last is None else last + 1
    title = (body.title or "").strip() or f"Page {position + 1}"
    page = Page(project_id=project_id, title=title, position=position)
    session.add(page)
    project.updated_at = utcnow()
    session.add(project)
    session.commit()
    session.refresh(page)
    return PageSummary.model_validate(page)


@router.post("/{project_id}/pages/reorder", response_model=list[PageSummary])
def reorder_pages(
    project_id: int, body: ReorderRequest, session: Session = Depends(get_session)
):
    project = get_project_or_404(session, project_id)
    pages = project_pages(session, project_id)
    if sorted(body.page_ids) != sorted(p.id for p in pages):
        raise HTTPException(
            400, "page_ids must contain every page of the project exactly once"
        )
    by_id = {p.id: p for p in pages}
    for index, pid in enumerate(body.page_ids):
        by_id[pid].position = index
        session.add(by_id[pid])
    project.updated_at = utcnow()
    session.add(project)
    session.commit()
    return [PageSummary.model_validate(by_id[pid]) for pid in body.page_ids]
EOF

cat > backend/app/routers/pages.py <<'EOF'
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse
from sqlmodel import Session, select

from app.canvas_models import Page, Project, utcnow
from app.db import get_session
from app.schemas import PageRead, PageRename, PageSummary, PageUpdate
from app.services.storage import delete_page_image, find_page_image, save_page_image
from app.services.transcript import text_from_content

router = APIRouter()


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


@router.get("/{page_id}", response_model=PageRead)
def get_page(page_id: int, session: Session = Depends(get_session)):
    return PageRead.model_validate(get_page_or_404(session, page_id))


@router.put("/{page_id}", response_model=PageSummary)
def save_page(page_id: int, body: PageUpdate, session: Session = Depends(get_session)):
    page = get_page_or_404(session, page_id)
    if body.image:
        try:
            save_page_image(page.id, body.image)
        except ValueError as e:
            raise HTTPException(400, str(e))
    page.content = body.content.model_dump(mode="json")  # new dict -> change detected
    page.transcript = text_from_content(page.content)
    page.transcript_status = "ready"
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

# ------------------------------------------------------------------ main
cat > backend/app/main.py <<'EOF'
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.core.config import settings
from app.db import init_db
from app.routers import chat, health, items, pages, projects
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
app.include_router(pages.router, prefix="/api/pages", tags=["pages"])

# uploaded / imported files, served at /files/...
app.mount("/files", StaticFiles(directory=STORAGE_DIR), name="files")
EOF

# ------------------------------------------------------------- gitignore
touch .gitignore
grep -q '^backend/storage/' .gitignore || printf '\n# uploaded files\nbackend/storage/\n' >> .gitignore

echo ""
echo "Done. Patch 1 installed (original main.py saved as backend/app/main.py.bak)."
echo "  - Restart the backend task. New tables are created automatically."
echo "  - Open http://localhost:8000/docs -> 'projects' and 'pages' sections."
echo "  - Tell your teammate the CRUD endpoints are live."