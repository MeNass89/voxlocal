"""Scripted model for the demo: H4's `ScriptedProvider` (harness/tests/test_loop.py), extended.

The loop test's provider answers from the conversation it receives: `record_find_sections` ->
`record_draft_edit` (examen clinique, then orientation, with verbatim quotes of the entorse
dictation) -> `record_apply` on each draft -> a French summary. The demo adds two things:

* the dictation id comes from the chat message (« Nouvelle dictée <id> ») instead of the fixture
  id, so the quotes point at the dictation the feeder actually delivered;
* a second clinician message asking to cancel (« Annulez … ») triggers `record_restore` on the
  backup of the last write, then a French confirmation.

The scripted model always drafts from the entorse transcript: use it with that seed only.

Run from the repository root:  python3 -m harness.demo.scripted_provider --port 47381
"""
from __future__ import annotations

import argparse
import re
import time
from http.server import ThreadingHTTPServer

from harness.tests import test_loop as loop

_original_next_move = loop.ScriptedProvider.next_move
CANCEL = re.compile(r"\b(annul|restaur)", re.IGNORECASE)


def _text(message: dict) -> str:
    content = message.get("content")
    if isinstance(content, list):
        return "".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content or ""


def next_move(messages: list[dict]) -> tuple[str, tuple[str, dict] | None]:
    users = [i for i, m in enumerate(messages) if m.get("role") == "user"]
    if users:
        found = re.search(r"Nouvelle dictée (\S+) \(", _text(messages[users[0]]))
        if found:
            loop.DICT = found.group(1)  # read by the loop test's next_move at call time
    if len(users) > 1 and CANCEL.search(_text(messages[users[-1]])):
        tail = messages[users[-1] + 1:]
        restored = [_text(m) for m in tail if m.get("role") == "tool"]
        if restored:
            return (f"{restored[-1].splitlines()[0].rstrip('.')}. La section est revenue à son texte d'avant "
                    "l'ajout ; rien d'autre n'a été modifié."), None
        backups = re.findall(r"sauvegarde (bak-[\w-]+)",
                             " ".join(_text(m) for m in messages[:users[-1]] if m.get("role") == "tool"))
        if backups:
            return "", ("record_restore", {"backup_id": backups[-1]})
        return "Aucune modification appliquée à annuler.", None
    return _original_next_move(messages)


# The loop test's HTTP handler calls `ScriptedProvider.next_move` by class name.
loop.ScriptedProvider.next_move = staticmethod(next_move)


def main() -> int:
    ap = argparse.ArgumentParser(description="Modèle scripté OpenAI-compatible pour la démo du harness.")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--delay", type=float, default=0.0,
                    help="secondes d'attente avant chaque réponse (rythme lisible pour la démo)")
    args = ap.parse_args()
    provider = loop.ScriptedProvider()
    provider.server.server_close()
    base = provider._handler()

    class Handler(base):
        def do_POST(self):
            time.sleep(max(0.0, args.delay))
            super().do_POST()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print(f"scripted provider: http://127.0.0.1:{server.server_port}/v1", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
