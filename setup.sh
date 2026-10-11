#!/usr/bin/env bash
# Adds OpenRouter LLM support to an EXISTING project created by setup.sh.
# Run from the project root (the folder that contains backend/ and frontend/):
#   bash add_openrouter.sh
# Safe to re-run. Does not touch the frontend, git, or your installed packages.
set -e

if [ ! -f backend/app/main.py ]; then
  echo "!! Run this from the project root (backend/app/main.py not found here)."
  exit 1
fi

# ---- 1. env files ------------------------------------------------------
add_env() {
  f="$1"
  [ -f "$f" ] || touch "$f"
  if ! grep -q '^OPENROUTER_API_KEY' "$f"; then
    {
      echo ""
      echo "# Get a key at https://openrouter.ai/keys  (backend only, never in the frontend)"
      echo "OPENROUTER_API_KEY="
      echo "# Any model id from https://openrouter.ai/models (openrouter/auto lets OpenRouter pick)"
      echo "LLM_MODEL=openrouter/auto"
    } >> "$f"
    echo ">> Added OpenRouter vars to $f"
  fi
}
add_env backend/.env
add_env backend/.env.example

# ---- 2. settings -------------------------------------------------------
if ! grep -q 'openrouter_api_key' backend/app/core/config.py; then
  sed -i '/cors_origins: list\[str\]/a\    openrouter_api_key: str = ""\n    llm_model: str = "openrouter/auto"' backend/app/core/config.py
  echo ">> Updated backend/app/core/config.py"
fi

# ---- 3. LLM service ----------------------------------------------------
cat > backend/app/services/llm.py <<'EOF'
# LLM access through OpenRouter (OpenAI-compatible API, one key, many models).
# Put all AI / third-party API calls here so routers stay thin.
import httpx

from app.core.config import settings

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"


class LLMError(Exception):
    pass


def chat(
    messages: list[dict],
    model: str | None = None,
    temperature: float | None = None,
) -> str:
    """Send a full chat history: [{"role": "user"|"assistant"|"system", "content": "..."}]"""
    if not settings.openrouter_api_key:
        raise LLMError("OPENROUTER_API_KEY is not set in backend/.env")

    payload: dict = {"model": model or settings.llm_model, "messages": messages}
    if temperature is not None:
        payload["temperature"] = temperature

    try:
        r = httpx.post(
            OPENROUTER_URL,
            headers={"Authorization": f"Bearer {settings.openrouter_api_key}"},
            json=payload,
            timeout=90,
        )
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]
    except httpx.HTTPStatusError as e:
        raise LLMError(f"OpenRouter {e.response.status_code}: {e.response.text[:300]}")
    except (httpx.HTTPError, KeyError, IndexError, ValueError) as e:
        raise LLMError(f"OpenRouter request failed: {e}")


def ask(prompt: str, system: str | None = None, model: str | None = None) -> str:
    """One-shot helper: ask(prompt) -> answer text."""
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    return chat(messages, model=model)
EOF
echo ">> Wrote backend/app/services/llm.py"

# ---- 4. /api/chat router -----------------------------------------------
cat > backend/app/routers/chat.py <<'EOF'
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.services import llm

router = APIRouter()


class Message(BaseModel):
    role: str  # "system" | "user" | "assistant"
    content: str


class ChatRequest(BaseModel):
    messages: list[Message]
    model: str | None = None  # override LLM_MODEL per request


class ChatResponse(BaseModel):
    reply: str


@router.post("", response_model=ChatResponse)
def chat(req: ChatRequest):
    try:
        reply = llm.chat([m.model_dump() for m in req.messages], model=req.model)
    except llm.LLMError as e:
        raise HTTPException(status_code=502, detail=str(e))
    return {"reply": reply}
EOF
echo ">> Wrote backend/app/routers/chat.py"

# ---- 5. wire router into main.py ---------------------------------------
if ! grep -q 'chat.router' backend/app/main.py; then
  sed -i 's/^from app.routers import health, items$/from app.routers import chat, health, items/' backend/app/main.py
  sed -i '/include_router(items.router/a app.include_router(chat.router, prefix="/api/chat", tags=["chat"])' backend/app/main.py
  echo ">> Updated backend/app/main.py"
fi

echo ""
echo "Done. Next:"
echo "  1. Put your key in backend/.env  ->  OPENROUTER_API_KEY=sk-or-..."
echo "  2. Restart the backend task (the .env file is only read at startup)"
echo "  3. Test:"
echo "     curl -X POST http://localhost:8000/api/chat -H 'Content-Type: application/json' \\"
echo "          -d '{\"messages\":[{\"role\":\"user\",\"content\":\"say hi\"}]}'"
echo "     (or try POST /api/chat at http://localhost:8000/docs)"