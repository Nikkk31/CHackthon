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
