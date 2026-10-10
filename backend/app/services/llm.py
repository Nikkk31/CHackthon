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
