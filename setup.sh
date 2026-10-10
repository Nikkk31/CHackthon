#!/usr/bin/env bash
# Hackathon starter: FastAPI (backend) + Next.js (frontend) monorepo.
# Run from INSIDE your project folder:  bash setup.sh
# Finds the python of conda env "ch" automatically (no activation needed).
# Overrides:  CONDA_ENV_NAME=other bash setup.sh   |   PY=/path/to/python.exe bash setup.sh
set -e

CONDA_ENV_NAME="${CONDA_ENV_NAME:-ch}"

if [ -z "${PY:-}" ]; then
  if [ "${CONDA_DEFAULT_ENV:-}" = "$CONDA_ENV_NAME" ] && command -v python >/dev/null 2>&1; then
    PY="$(command -v python)"
  else
    BASES=()
    if command -v conda >/dev/null 2>&1; then
      BASES+=("$(conda info --base 2>/dev/null | tr -d '\r')")
    fi
    BASES+=("$HOME/anaconda3" "$HOME/miniconda3" "$HOME/miniforge3" "$HOME/mambaforge" \
            "$HOME/.conda" "/c/ProgramData/anaconda3" "/c/ProgramData/miniconda3" \
            "/c/anaconda3" "/c/miniconda3")
    for base in "${BASES[@]}"; do
      [ -n "$base" ] || continue
      for cand in "$base/envs/$CONDA_ENV_NAME/python.exe" "$base/envs/$CONDA_ENV_NAME/bin/python"; do
        if [ -x "$cand" ]; then PY="$cand"; break 2; fi
      done
    done
  fi
fi

if [ -z "${PY:-}" ] || [ ! -x "$PY" ]; then
  echo "!! Could not find python for conda env '$CONDA_ENV_NAME'."
  echo "   In Anaconda Prompt run:  conda activate $CONDA_ENV_NAME  &&  where python"
  echo "   then re-run here:        PY=\"<that python.exe path>\" bash setup.sh"
  exit 1
fi

if command -v cygpath >/dev/null 2>&1; then PY_WIN="$(cygpath -m "$PY")"; else PY_WIN="$PY"; fi
echo ">> Using $("$PY" --version 2>&1) from $PY"

[ -d .git ] || git init -q

# ---------------------------------------------------------------- backend
mkdir -p backend/app/core backend/app/routers backend/app/services .vscode
touch backend/app/__init__.py backend/app/core/__init__.py \
      backend/app/routers/__init__.py backend/app/services/__init__.py

cat > backend/requirements.txt <<'EOF'
fastapi
uvicorn[standard]
sqlmodel
pydantic-settings
python-dotenv
python-multipart
httpx
EOF

cat > backend/.env.example <<'EOF'
APP_NAME=Hackathon API
DATABASE_URL=sqlite:///./app.db
CORS_ORIGINS=["http://localhost:3000"]
# Add API keys here, e.g.
# OPENAI_API_KEY=
# ANTHROPIC_API_KEY=
EOF
cp backend/.env.example backend/.env

cat > backend/app/core/config.py <<'EOF'
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "Hackathon API"
    database_url: str = "sqlite:///./app.db"
    cors_origins: list[str] = ["http://localhost:3000"]

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")


settings = Settings()
EOF

cat > backend/app/db.py <<'EOF'
from sqlmodel import Session, SQLModel, create_engine

from app.core.config import settings

engine = create_engine(
    settings.database_url, connect_args={"check_same_thread": False}
)


def init_db() -> None:
    SQLModel.metadata.create_all(engine)


def get_session():
    with Session(engine) as session:
        yield session
EOF

cat > backend/app/models.py <<'EOF'
from sqlmodel import Field, SQLModel


class ItemBase(SQLModel):
    title: str
    description: str | None = None


class Item(ItemBase, table=True):
    id: int | None = Field(default=None, primary_key=True)


class ItemCreate(ItemBase):
    pass
EOF

cat > backend/app/routers/health.py <<'EOF'
from fastapi import APIRouter

router = APIRouter()


@router.get("/health")
def health():
    return {"status": "ok"}
EOF

cat > backend/app/routers/items.py <<'EOF'
# Example CRUD router -- copy this pattern for each new resource.
from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session, select

from app.db import get_session
from app.models import Item, ItemCreate

router = APIRouter()


@router.get("", response_model=list[Item])
def list_items(session: Session = Depends(get_session)):
    return session.exec(select(Item)).all()


@router.post("", response_model=Item)
def create_item(data: ItemCreate, session: Session = Depends(get_session)):
    item = Item.model_validate(data)
    session.add(item)
    session.commit()
    session.refresh(item)
    return item


@router.delete("/{item_id}")
def delete_item(item_id: int, session: Session = Depends(get_session)):
    item = session.get(Item, item_id)
    if not item:
        raise HTTPException(404, "Item not found")
    session.delete(item)
    session.commit()
    return {"ok": True}
EOF

cat > backend/app/services/llm.py <<'EOF'
# Put AI / third-party API calls here so routers stay thin.
# Example (Anthropic):
#   pip install anthropic
#   import anthropic
#   client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY
#   def ask(prompt: str) -> str:
#       msg = client.messages.create(
#           model="claude-sonnet-5-5",
#           max_tokens=1024,
#           messages=[{"role": "user", "content": prompt}],
#       )
#       return msg.content[0].text


def ask(prompt: str) -> str:
    raise NotImplementedError("Wire up your LLM provider here")
EOF

cat > backend/app/main.py <<'EOF'
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import settings
from app.db import init_db
from app.routers import health, items


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
EOF

echo ">> Installing backend deps into conda env '$CONDA_ENV_NAME' ($PY_WIN)..."
"$PY" -m pip install -q -r backend/requirements.txt

# --------------------------------------------------------------- frontend
echo ">> Creating Next.js app..."
npx --yes create-next-app@latest frontend \
  --ts --tailwind --eslint --app --src-dir --import-alias "@/*" --use-npm --yes

mkdir -p frontend/src/lib

cat > frontend/.env.local <<'EOF'
NEXT_PUBLIC_API_URL=http://localhost:8000
EOF
cp frontend/.env.local frontend/.env.example

cat > frontend/src/lib/api.ts <<'EOF'
const BASE = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

export async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}/api${path}`, {
    headers: { "Content-Type": "application/json" },
    ...init,
  });
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  return res.json() as Promise<T>;
}
EOF

cat > frontend/src/app/page.tsx <<'EOF'
"use client";

import { useEffect, useState } from "react";
import { api } from "@/lib/api";

type Item = { id: number; title: string; description?: string | null };

export default function Home() {
  const [items, setItems] = useState<Item[]>([]);
  const [title, setTitle] = useState("");
  const [status, setStatus] = useState("checking...");

  const load = () => api<Item[]>("/items").then(setItems).catch(() => {});

  useEffect(() => {
    api<{ status: string }>("/health")
      .then((r) => setStatus(r.status))
      .catch(() => setStatus("backend unreachable"));
    load();
  }, []);

  async function add(e: React.FormEvent) {
    e.preventDefault();
    if (!title.trim()) return;
    await api("/items", { method: "POST", body: JSON.stringify({ title }) });
    setTitle("");
    load();
  }

  async function remove(id: number) {
    await api(`/items/${id}`, { method: "DELETE" });
    load();
  }

  return (
    <main className="mx-auto max-w-xl p-8">
      <h1 className="text-2xl font-bold">Hackathon Starter</h1>
      <p className="mb-6 text-sm text-gray-500">API status: {status}</p>

      <form onSubmit={add} className="mb-4 flex gap-2">
        <input
          className="flex-1 rounded border px-3 py-2"
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          placeholder="New item"
        />
        <button className="rounded bg-black px-4 py-2 text-white">Add</button>
      </form>

      <ul className="space-y-2">
        {items.map((i) => (
          <li key={i.id} className="flex justify-between rounded border p-3">
            {i.title}
            <button onClick={() => remove(i.id)} className="text-red-500">
              delete
            </button>
          </li>
        ))}
      </ul>
    </main>
  );
}
EOF

# ------------------------------------------------------------ root / vscode
cat > .gitignore <<'EOF'
# python
__pycache__/
*.pyc
.venv/
*.db
# env
.env
.env.local
# node
node_modules/
.next/
# os / editor
.DS_Store
EOF

cat > .vscode/tasks.json <<'EOF'
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "backend",
      "type": "process",
      "command": "__PY__",
      "args": ["-m", "uvicorn", "app.main:app", "--reload", "--port", "8000"],
      "options": { "cwd": "${workspaceFolder}/backend" },
      "isBackground": true,
      "problemMatcher": [],
      "presentation": { "group": "dev" }
    },
    {
      "label": "frontend",
      "type": "shell",
      "command": "npm run dev",
      "options": { "cwd": "${workspaceFolder}/frontend" },
      "isBackground": true,
      "problemMatcher": [],
      "presentation": { "group": "dev" }
    },
    {
      "label": "dev (both)",
      "dependsOn": ["backend", "frontend"],
      "problemMatcher": []
    }
  ]
}
EOF

sed -i "s|__PY__|$PY_WIN|" .vscode/tasks.json

cat > .vscode/settings.json <<EOF
{
  "python.defaultInterpreterPath": "$PY_WIN",
  "editor.formatOnSave": true
}
EOF

cat > README.md <<'EOF'
# Hackathon Starter

FastAPI backend + Next.js frontend.

## Run
- VS Code: `Ctrl/Cmd+Shift+P` -> **Tasks: Run Task** -> **dev (both)**
- Or manually:
  - Backend:  `conda activate ch && cd backend && uvicorn app.main:app --reload`
  - Frontend: `cd frontend && npm run dev`

Frontend: http://localhost:3000 | API docs: http://localhost:8000/docs

## Layout
```
backend/app/
  main.py        app + CORS + router wiring
  models.py      SQLModel tables / schemas
  db.py          SQLite engine + session
  routers/       one file per resource (see items.py)
  services/      LLM / external API logic (llm.py)
frontend/src/
  app/           pages (App Router)
  lib/api.ts     typed fetch helper for the backend
```

## Deploy (do this early!)
- Frontend -> Vercel (set `NEXT_PUBLIC_API_URL`)
- Backend  -> Render / Railway (`uvicorn app.main:app --host 0.0.0.0 --port $PORT`),
  then add the Vercel URL to `CORS_ORIGINS`.
EOF

git add -A
git commit -q -m "Initial hackathon scaffold" || true

echo ""
echo "Done! Open this folder in VS Code (code .)"
echo "Then: Ctrl+Shift+P -> Tasks: Run Task -> 'dev (both)'"