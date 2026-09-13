#!/usr/bin/env python3
"""
hook.py — registra o estado de cada sessao do Claude Code em disco.

Um unico script atende varios eventos. Ele le o JSON do stdin, olha o campo
hook_event_name e grava o estado da sessao em
<config dir>/claude-bar/sessions/<session_id>.json -- onde <config dir> e o
CLAUDE_CONFIG_DIR desta sessao (~/.claude quando nao ha um), para que cada conta
do Claude Code tenha o seu. Ver state_dir() abaixo.

Ele NAO decide nada: nunca imprime permissionDecision, nunca sai com codigo 2.
Sai sempre 0. Se quebrar, o Claude Code segue normal.

Eventos usados:
  SessionStart      -> registra sessao (state=idle)
  UserPromptSubmit  -> state=working
  PermissionRequest -> state=waiting  (sinal primario: dispara no instante do pedido)
  PermissionDenied  -> state=working  (voce negou; o Claude segue)
  PostToolUse       -> state=working  (a ferramenta rodou: aprovacao saiu)
  PostToolUseFailure-> state=working  (idem, com erro)
  Notification      -> state=waiting (permission_prompt / agent_needs_input)
                       ou idle (idle_prompt)
  Stop              -> state=done
  SessionEnd        -> remove o arquivo da sessao

Por que PermissionRequest e nao so Notification: o Claude Code so emite a
Notification de permission_prompt num setInterval de 6s, e apenas se voce nao
encostou no teclado desde que o dialogo abriu (ele reseta lastInteractionTime
ao montar). Aprovacao respondida em menos de 6s -- a maioria -- nunca gerava
evento, e a sessao bloqueada ficava invisivel na menu bar. PermissionRequest
dispara junto com o pedido, sem janela nem gate de foco. A Notification fica
como rede de seguranca (agent_needs_input, elicitation, versoes antigas).
"""

import json
import os
import sys
import time


def state_dir():
    """Diretorio de estado desta conta: <config dir do Claude Code>/claude-bar.

    Cada conta vive num CLAUDE_CONFIG_DIR proprio (a padrao e ~/.claude), e o
    estado segue essa divisao em vez de um diretorio unico e compartilhado. Nao e
    organizacao: e o que impede o uso de uma conta sobrescrever o da outra no
    mesmo usage.json, o DEBUG de uma capturar conversa da outra, e desinstalar
    uma conta levar junto o estado das demais. O app acha as contas pelo mesmo
    caminho -- ver Accounts.discover no ClaudeBarLocal.swift.
    """
    cfg = os.environ.get("CLAUDE_CONFIG_DIR", "").strip() or "~/.claude"
    return os.path.join(os.path.expanduser(cfg), "claude-bar")


STATE_DIR = state_dir()
SESSIONS_DIR = os.path.join(STATE_DIR, "sessions")
DEBUG_FLAG = os.path.join(STATE_DIR, "DEBUG")
DEBUG_LOG = os.path.join(STATE_DIR, "debug.jsonl")

# notification_type que significa "o Claude travou e esta esperando voce".
# Laranja e reservado para o que bloqueia o trabalho: idle_prompt NAO entra aqui,
# porque "terminou, e sua vez" ja e o Stop -> done (verde). Laranja em tudo vira
# ruido e voce para de olhar.
WAITING_TYPES = ("permission_prompt", "agent_needs_input", "elicitation_dialog")
IDLE_TYPES = ("idle_prompt",)
# Notificacoes que nao dizem nada sobre o estado da sessao: nao gravam.
IGNORED_TYPES = ("auth_success", "agent_completed", "elicitation_complete",
                 "elicitation_response")


def atomic_write(path, payload):
    """Grava JSON atomicamente. O tmp ja nasce 0600 (nao ha janela world-readable)."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.replace(tmp, path)


def debug_dump(raw):
    """Se <config dir>/claude-bar/DEBUG existir, apenda o stdin cru para inspecao.

    A flag e por conta, e nao global, de proposito: ligar o diagnostico numa
    conta nao pode fazer o stdin cru de outra -- que carrega conteudo de sessao --
    parar no mesmo arquivo.

    Flag por arquivo em vez de env var: hooks nao herdam ambiente de shell de
    forma confiavel, e um touch/rm liga e desliga.
    """
    try:
        if not os.path.exists(DEBUG_FLAG):
            return
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        fd = os.open(DEBUG_LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"src": "hook", "at": int(time.time()), "raw": raw}) + "\n")
    except Exception:
        pass


# Ferramentas cujo PostToolUse encerra uma espera. Guardado por nome porque o
# PermissionRequest nao carrega tool_use_id: com chamadas em paralelo (uma
# auto-aprovada, outra no dialogo) casar pelo nome evita que o PostToolUse da
# aprovada apague o waiting da que ainda esta parada.
RESOLVING_EVENTS = ("PostToolUse", "PostToolUseFailure")


def classify(event, data):
    """Devolve (state, label) a partir do evento."""
    if event == "SessionStart":
        return "idle", ""
    if event == "UserPromptSubmit":
        return "working", "processando"
    if event == "Stop":
        return "done", "terminou"
    if event == "PermissionRequest":
        tool = str(data.get("tool_name") or "").strip()
        # So o nome da ferramenta. tool_input nao entra no label: ele carrega o
        # comando/arquivo inteiro, e esse arquivo vira texto na menu bar.
        return "waiting", ("aprovar %s" % tool) if tool else "aguardando aprovacao"
    if event == "PermissionDenied":
        return "working", "processando"
    if event == "Notification":
        return classify_notification(data)
    return None, ""


def classify_notification(data):
    """Classifica por notification_type; cai para heuristica de texto se faltar."""
    ntype = str(data.get("notification_type") or "")
    msg = str(data.get("message") or "")
    if ntype:
        if ntype in WAITING_TYPES:
            return "waiting", msg or "precisa de voce"
        if ntype in IDLE_TYPES:
            return "idle", msg or "ocioso"
        if ntype in IGNORED_TYPES:
            return None, ""
        # Tipo novo/desconhecido: nao inventa estado.
        return None, ""

    # Fallback para versoes do Claude Code sem notification_type.
    low = msg.lower()
    if "permission" in low or "approve" in low or "permiss" in low:
        return "waiting", msg or "aguardando aprovacao"
    if "waiting for your input" in low or "idle" in low:
        return "idle", msg or "ocioso"
    return "waiting", msg or "precisa de voce"


def main():
    raw = sys.stdin.read()
    debug_dump(raw)
    try:
        data = json.loads(raw)
    except Exception:
        return 0

    event = data.get("hook_event_name") or ""
    session_id = data.get("session_id") or "unknown"
    cwd = data.get("cwd") or ""
    path = os.path.join(SESSIONS_DIR, "%s.json" % session_id)

    if event == "SessionEnd":
        try:
            os.remove(path)
        except OSError:
            pass
        return 0

    current = {}
    try:
        if os.path.exists(path):
            with open(path, encoding="utf-8") as fh:
                current = json.load(fh)
    except Exception:
        current = {}

    if event in RESOLVING_EVENTS:
        # PostToolUse dispara em toda ferramenta. Se a sessao nao estava travada,
        # nao ha nada a dizer: sai sem escrever, para nao pagar um write por
        # chamada de ferramenta so para regravar o mesmo estado.
        if current.get("state") != "waiting":
            return 0
        pending = current.get("waiting_tool") or ""
        if pending and str(data.get("tool_name") or "") != pending:
            return 0
        state, label = "working", "processando"
    else:
        state, label = classify(event, data)
        if state is None:
            return 0

    if state == "waiting":
        current["waiting_tool"] = str(data.get("tool_name") or "")
    else:
        current.pop("waiting_tool", None)

    current.update({
        "session_id": session_id,
        "cwd": cwd,
        "project": os.path.basename(cwd.rstrip("/")) or cwd,
        "state": state,
        "label": label,
        "last_event": event,
        "updated_at": int(time.time()),
    })

    try:
        atomic_write(path, current)
    except Exception:
        pass

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
