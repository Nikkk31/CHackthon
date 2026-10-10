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
