#!/usr/bin/env python3
"""
statusline.py — statusline do Claude Code + bomba de dados para a menu bar.

Lê o JSON que o Claude Code manda no stdin, grava um snapshot em
<config dir>/claude-bar/usage.json e imprime uma linha para o terminal.

O <config dir> e o CLAUDE_CONFIG_DIR desta sessao (~/.claude quando nao ha um),
entao cada conta do Claude Code escreve no seu proprio diretorio -- ver
state_dir() logo abaixo.

NAO faz chamada de rede. NAO le credencial. NAO escreve fora de
<config dir>/claude-bar/. Sai com 0 em qualquer situacao para nunca
derrubar a statusline.
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
USAGE_FILE = os.path.join(STATE_DIR, "usage.json")
SESSIONS_DIR = os.path.join(STATE_DIR, "sessions")
DEBUG_FLAG = os.path.join(STATE_DIR, "DEBUG")
DEBUG_LOG = os.path.join(STATE_DIR, "debug.jsonl")

RESET = "\033[0m"
DIM = "\033[2m"
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"


def atomic_write(path, payload):
    """Grava JSON atomicamente (tmp + rename) para o leitor nunca ver arquivo pela metade.

    O tmp ja nasce 0600 e o diretorio 0700: sem janela world-readable, e outro
    usuario local nao lista seus session ids nem nomes de projeto.
    """
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
    """
    try:
        if not os.path.exists(DEBUG_FLAG):
            return
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        fd = os.open(DEBUG_LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"src": "statusline", "at": int(time.time()),
                                 "raw": raw}) + "\n")
    except Exception:
        pass


def bar(pct, width=10):
    pct = max(0, min(100, int(pct)))
    filled = pct * width // 100
    return "\u2593" * filled + "\u2591" * (width - filled)


def color_for(pct):
    if pct >= 85:
        return RED
    if pct >= 60:
        return YELLOW
    return GREEN


def fmt_reset(epoch):
    """resets_at da statusline e epoch Unix em segundos (confirmado na doc).

    Protegido de qualquer forma: esta funcao e chamada na montagem da linha, e
    uma excecao aqui abortaria o print inteiro -- a statusline sairia vazia.
    """
    try:
        if not epoch:
            return None
        delta = int(epoch) - int(time.time())
    except (TypeError, ValueError):
        return None
    if delta <= 0:
        return "agora"
    h, m = delta // 3600, (delta % 3600) // 60
    return ("%dh%02dm" % (h, m)) if h else ("%dm" % m)


def main():
    raw = sys.stdin.read()
    debug_dump(raw)
    try:
        data = json.loads(raw)
    except Exception:
        return 0

    model = (data.get("model") or {}).get("display_name") or "?"
    ctx = (data.get("context_window") or {}).get("used_percentage")
    ctx = int(ctx) if ctx is not None else None
    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or ""
    session_id = data.get("session_id") or "unknown"
    cost = (data.get("cost") or {}).get("total_cost_usd") or 0.0

    limits = data.get("rate_limits") or {}
    five = limits.get("five_hour") or {}
    seven = limits.get("seven_day") or {}
    five_pct = five.get("used_percentage")
    seven_pct = seven.get("used_percentage")

    snapshot = {
        "updated_at": int(time.time()),
        "model": model,
        "context_pct": ctx,
        "session_cost_usd": round(float(cost), 4),
        "five_hour_pct": round(float(five_pct), 1) if five_pct is not None else None,
        "five_hour_resets_at": five.get("resets_at"),
        "seven_day_pct": round(float(seven_pct), 1) if seven_pct is not None else None,
        "seven_day_resets_at": seven.get("resets_at"),
    }

    # usage.json so e reescrito quando ha numero de limite; assim a menu bar
    # nao perde o ultimo valor bom nas primeiras chamadas da sessao.
    try:
        if five_pct is not None or seven_pct is not None:
            atomic_write(USAGE_FILE, snapshot)
    except Exception:
        pass

    # carimba modelo/contexto na sessao (a menu bar mostra por sessao)
    try:
        sess_path = os.path.join(SESSIONS_DIR, "%s.json" % session_id)
        current = {}
        if os.path.exists(sess_path):
            with open(sess_path, encoding="utf-8") as fh:
                current = json.load(fh)
        current.update({
            "session_id": session_id,
            "cwd": cwd,
            "project": os.path.basename(cwd.rstrip("/")) or cwd,
            "model": model,
            "context_pct": ctx,
            "seen_at": int(time.time()),
        })
        current.setdefault("state", "idle")
        atomic_write(sess_path, current)
    except Exception:
        pass

    parts = ["%s[%s]%s" % (CYAN, model, RESET)]
    if cwd:
        parts.append("%s\U0001f4c1 %s%s" % (DIM, os.path.basename(cwd.rstrip("/")), RESET))
    if ctx is not None:
        parts.append("ctx %d%%" % ctx)
    if five_pct is not None:
        p = int(five_pct)
        seg = "%s5h %s %d%%%s" % (color_for(p), bar(p), p, RESET)
        rst = fmt_reset(five.get("resets_at"))
        if rst:
            seg += " %s\u21bb%s%s" % (DIM, rst, RESET)
        parts.append(seg)
    if seven_pct is not None:
        p = int(seven_pct)
        parts.append("%s7d %d%%%s" % (color_for(p), p, RESET))

    sys.stdout.write(" \u2502 ".join(parts) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
