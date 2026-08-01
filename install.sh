#!/bin/bash
# Instala o claude-bar-local: scripts, hooks no settings.json e o app.
#
# O passo que justifica este script e o settings.json: mesclar JSON a mao e onde
# alguem quebra o proprio arquivo. Aqui a regra e nao destruir nada -- backup
# antes, entradas suas preservadas, e se o JSON atual estiver invalido o script
# aborta sem escrever uma linha.
#
# Uso:
#   ./install.sh                 instala (scripts + settings.json + app)
#   ./install.sh --autostart     idem, e sobe no login via LaunchAgent
#   ./install.sh --dry-run       mostra o que mudaria, sem tocar em nada
#   ./install.sh --uninstall     desfaz tudo
set -euo pipefail

cd "$(dirname "$0")"

AUTOSTART=0
DRY_RUN=0
UNINSTALL=0

for arg in "$@"; do
  case "$arg" in
    --autostart) AUTOSTART=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "argumento desconhecido: $arg (use --help)" >&2
      exit 1 ;;
  esac
done

STATE_DIR="$HOME/.claude/claude-bar"
SETTINGS="$HOME/.claude/settings.json"
AGENT="$HOME/Library/LaunchAgents/local.claudebar.plist"
APP="ClaudeBarLocal.app"
INSTALLED_APP="/Applications/$APP"
LABEL="local.claudebar"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# O merge (e o unmerge) do settings.json. Fica numa funcao porque instalar e
# desinstalar usam exatamente a mesma logica, so mudando o modo.
merge_settings() {  # $1 = install|uninstall
  python3 - "$SETTINGS" "$1" "$DRY_RUN" <<'PY'
import json, os, shutil, sys, time

path, mode, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

# Marcadores: e por eles que o script reconhece o que e dele. Qualquer outra
# statusline ou hook seu nao casa, e por isso nunca e tocado.
MARK_HOOK = "claude-bar/hook.py"
MARK_LINE = "claude-bar/statusline.py"

EVENTS = ["SessionStart", "UserPromptSubmit", "PermissionRequest",
          "PermissionDenied", "PostToolUse", "PostToolUseFailure",
          "Notification", "Stop", "SessionEnd"]

STATUSLINE = {"type": "command",
              "command": "python3 ~/.claude/claude-bar/statusline.py",
              "padding": 1,
              "refreshInterval": 10}

def hook_entry():
    return {"hooks": [{"type": "command",
                       "command": "python3 ~/.claude/claude-bar/hook.py",
                       "async": True}]}

def is_ours(obj):
    return MARK_HOOK in json.dumps(obj)

original = ""
root = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    if original.strip():
        try:
            root = json.loads(original)
        except ValueError as e:
            sys.stderr.write(
                "ERRO: %s nao e JSON valido (%s).\n"
                "Nada foi alterado. Conserte o arquivo e rode de novo.\n" % (path, e))
            sys.exit(1)
        if not isinstance(root, dict):
            sys.stderr.write("ERRO: %s nao tem um objeto na raiz. Nada foi alterado.\n" % path)
            sys.exit(1)

before = json.dumps(root, sort_keys=True)
notes = []

if mode == "install":
    current = root.get("statusLine")
    if current is None:
        root["statusLine"] = STATUSLINE
        notes.append("statusLine: instalada")
    elif isinstance(current, dict) and MARK_LINE in str(current.get("command", "")):
        notes.append("statusLine: ja era esta (preservada como esta, com seus ajustes)")
    else:
        # Sobrescrever aqui seria trocar a statusline de alguem sem avisar. So
        # uma roda: a escolha e do dono do arquivo, nao do instalador.
        notes.append("statusLine: VOCE JA TEM OUTRA -- preservada, a deste projeto NAO foi "
                     "instalada.\n              atual: %s\n              para trocar, edite %s a mao."
                     % (current.get("command", "?"), path))

    hooks = root.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
    added = []
    for event in EVENTS:
        entries = hooks.get(event)
        if not isinstance(entries, list):
            entries = [] if entries is None else [entries]
        if any(is_ours(e) for e in entries):
            continue
        entries.append(hook_entry())
        hooks[event] = entries
        added.append(event)
    if hooks:
        root["hooks"] = hooks
    notes.append("hooks: %s" % (", ".join(added) if added else "os 9 ja estavam registrados"))

else:  # uninstall
    current = root.get("statusLine")
    if isinstance(current, dict) and MARK_LINE in str(current.get("command", "")):
        del root["statusLine"]
        notes.append("statusLine: removida")
    elif current is not None:
        notes.append("statusLine: nao e deste projeto -- preservada")

    hooks = root.get("hooks")
    removed = []
    if isinstance(hooks, dict):
        for event in list(hooks.keys()):
            entries = hooks.get(event)
            if not isinstance(entries, list):
                continue
            kept = []
            for entry in entries:
                if is_ours(entry):
                    # Entrada compartilhada (hooks seus no mesmo bloco): tira so
                    # o nosso comando e mantem o resto.
                    inner = entry.get("hooks") if isinstance(entry, dict) else None
                    if isinstance(inner, list):
                        survivors = [h for h in inner if MARK_HOOK not in json.dumps(h)]
                        if survivors:
                            entry["hooks"] = survivors
                            kept.append(entry)
                    removed.append(event)
                else:
                    kept.append(entry)
            if kept:
                hooks[event] = kept
            else:
                del hooks[event]
        if not hooks:
            del root["hooks"]
    notes.append("hooks: %s" % (", ".join(sorted(set(removed))) if removed
                                else "nenhum deste projeto estava registrado"))

after = json.dumps(root, sort_keys=True)
for note in notes:
    print("  " + note)

if after == before:
    print("  (settings.json ja estava como deveria -- nao foi reescrito)")
    sys.exit(0)

if dry:
    print("  [dry-run] settings.json NAO foi escrito")
    sys.exit(0)

if original:
    backup = "%s.bak.%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(path, backup)
    print("  backup: %s" % backup)

# Escrita atomica: um Ctrl-C no meio nao deixa o settings.json pela metade.
os.makedirs(os.path.dirname(path), exist_ok=True)
mode_bits = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o600
tmp = "%s.tmp.%d" % (path, os.getpid())
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode_bits)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(root, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.replace(tmp, path)
print("  settings.json: escrito")
PY
}

# ---------------------------------------------------------------- desinstalar

if [ "$UNINSTALL" = "1" ]; then
  say "Desinstalando o claude-bar-local."
  [ "$DRY_RUN" = "1" ] && warn "modo --dry-run: nada sera alterado."

  step "1/4  settings.json"
  merge_settings uninstall

  step "2/4  LaunchAgent"
  if [ -f "$AGENT" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      say "  [dry-run] removeria $AGENT"
    else
      launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
      rm -f "$AGENT"
      say "  removido"
    fi
  else
    say "  nao havia LaunchAgent"
  fi

  step "3/4  App"
  if [ "$DRY_RUN" = "1" ]; then
    say "  [dry-run] encerraria o app e removeria $INSTALLED_APP"
  else
    pkill -f "$APP/Contents/MacOS/ClaudeBarLocal" 2>/dev/null || true
    rm -rf "$INSTALLED_APP"
    say "  encerrado; $INSTALLED_APP removido (o .app da pasta do repo fica)"
  fi

  step "4/4  Estado em disco"
  if [ "$DRY_RUN" = "1" ]; then
    say "  [dry-run] removeria $STATE_DIR"
  else
    rm -rf "$STATE_DIR"
    say "  $STATE_DIR removido (scripts, usage.json, sessoes)"
  fi

  say ""
  say "Pronto. Reinicie as sessoes do Claude Code abertas para os hooks sairem de vez."
  exit 0
fi

# ------------------------------------------------------------------ instalar

say "Instalando o claude-bar-local."
[ "$DRY_RUN" = "1" ] && warn "modo --dry-run: nada sera alterado."

step "1/5  Pre-requisitos"

MACOS="$(sw_vers -productVersion)"
if [ "${MACOS%%.*}" -lt 13 ]; then
  die "macOS $MACOS. O app exige 13.0 ou mais novo."
fi
say "  macOS $MACOS  ok"

command -v swiftc >/dev/null || die "swiftc nao encontrado. Rode: xcode-select --install"
say "  swiftc        ok"

command -v python3 >/dev/null || die "python3 nao encontrado. Rode: xcode-select --install"
say "  python3       ok"

if command -v claude >/dev/null; then
  say "  claude        ok ($(claude --version 2>/dev/null | head -1))"
else
  # Nao e fatal: da para instalar antes do CLI. Mas sem Claude Code nada alimenta
  # os hooks, e o painel nasce vazio -- melhor dizer agora do que deixar procurar.
  warn "  claude        NAO encontrado no PATH -- instale o Claude Code, senao nada alimenta o app"
fi

for f in statusline.py hook.py ClaudeBarLocal.swift build.sh; do
  [ -f "$f" ] || die "$f nao esta aqui. Rode o script de dentro do repositorio."
done

# Um py_compile antes de copiar: script quebrado vira statusline quebrada em
# todos os projetos, e o erro aparece longe daqui.
python3 -c "import ast,sys
for f in ('statusline.py','hook.py'):
    ast.parse(open(f, encoding='utf-8').read(), f)" || die "statusline.py/hook.py nao compilam. Nada foi instalado."
say "  scripts       sintaxe ok"

# O settings.json e conferido aqui, e nao la no passo 3, para um arquivo quebrado
# abortar antes de qualquer copia -- desistir no meio deixaria scripts instalados
# sem hook nenhum apontando para eles.
if [ -f "$SETTINGS" ]; then
  python3 -c "
import json,sys
text = open(sys.argv[1], encoding='utf-8').read()
if text.strip():
    d = json.loads(text)
    if not isinstance(d, dict): raise SystemExit('raiz nao e objeto')
" "$SETTINGS" 2>/dev/null \
    || die "  settings.json  NAO e JSON valido: $SETTINGS
                Nada foi instalado. Conserte o arquivo (ou renomeie) e rode de novo."
  say "  settings.json ok"
else
  say "  settings.json sera criado"
fi

step "2/5  Scripts -> $STATE_DIR"
if [ "$DRY_RUN" = "1" ]; then
  say "  [dry-run] copiaria statusline.py e hook.py"
else
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  cp statusline.py hook.py "$STATE_DIR/"
  chmod +x "$STATE_DIR/statusline.py" "$STATE_DIR/hook.py"
  say "  copiados (diretorio 0700)"
fi

step "3/5  settings.json"
merge_settings install

step "4/5  App"
if [ "$DRY_RUN" = "1" ]; then
  say "  [dry-run] rodaria ./build.sh"
else
  ./build.sh >/dev/null || die "build falhou. Rode ./build.sh direto para ver o erro."
  say "  compilado: $(pwd)/$APP"
  pkill -f "$APP/Contents/MacOS/ClaudeBarLocal" 2>/dev/null || true
fi

step "5/5  Auto-start"
if [ "$AUTOSTART" = "1" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    say "  [dry-run] instalaria em /Applications e carregaria o LaunchAgent"
  else
    rm -rf "$INSTALLED_APP"
    cp -R "$APP" /Applications/
    mkdir -p "$(dirname "$AGENT")"
    cp local.claudebar.plist "$AGENT"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
    say "  $INSTALLED_APP + LaunchAgent carregado (sobe no login)"
  fi
else
  say "  pulado (use --autostart para subir no login)"
fi

if [ "$DRY_RUN" = "1" ]; then
  say ""
  say "Fim do dry-run. Rode sem --dry-run para aplicar."
  exit 0
fi

if [ "$AUTOSTART" != "1" ]; then
  open "$APP"
fi

say ""
say "Pronto. O icone esta na menu bar (o app nao aparece no Dock, de proposito)."
say ""
say "Confira:"
say "  /hooks               dentro do Claude Code, lista o que ficou registrado"
say "  a statusline         so aparece no CLI; a extensao do VS Code nao a executa"
say ""
say "Desfazer tudo:  ./install.sh --uninstall"
