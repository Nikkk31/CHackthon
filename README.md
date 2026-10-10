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
