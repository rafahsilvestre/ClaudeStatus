# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## O que é

Monitor de menu bar do Claude Code para macOS 13+. Três peças que se comunicam
por arquivos em `~/.claude/claude-bar/`, sem servidor, sem daemon próprio e sem
dependência de terceiro:

- `ClaudeBarLocal.swift` — o app inteiro num arquivo (~2.5k linhas, dividido por
  `// MARK:`). SwiftUI + AppKit, compilado direto por `swiftc`, sem projeto Xcode.
- `statusline.py` / `hook.py` — statusline e hooks do Claude Code. Escrevem
  estado; não decidem nada.
- `install.sh` / `build.sh` — instalação (com merge seguro do `settings.json`) e
  compilação.

O README é a especificação: cada decisão não óbvia está justificada lá e nos
comentários do código, quase sempre com a medição que motivou. Ao mudar
comportamento, atualize a justificativa junto — comentário que descreve o
passado é pior que comentário nenhum.

## Comandos

```bash
./build.sh                    # compila o .app (ad-hoc signed, ~10s)
./install.sh --dry-run        # o que a instalação mudaria, sem escrever
./install.sh                  # scripts + settings.json + app
./install.sh --uninstall      # desfaz (remove só o que é deste projeto)

# typecheck rápido, sem gerar binário — o loop de edição do Swift
swiftc -typecheck -parse-as-library -target arm64-apple-macos13.0 ClaudeBarLocal.swift

# relançar depois de compilar
pkill -f "ClaudeBarLocal.app/Contents/MacOS/ClaudeBarLocal"; open ClaudeBarLocal.app

# ver o JSON cru que o Claude Code manda nos hooks/statusline desta versão
touch ~/.claude/claude-bar/DEBUG   # ... use o Claude Code ... depois:
python3 -m json.tool < ~/.claude/claude-bar/debug.jsonl
rm ~/.claude/claude-bar/DEBUG ~/.claude/claude-bar/debug.jsonl
```

**Não há suíte de testes.** A verificação é feita assim:

- scripts Python: `python3 -c "import ast; ast.parse(open('hook.py').read())"` e o
  bloco *Verificar você mesmo* do README (símbolos de rede, ausência de `SecItem`);
- `install.sh`: rode com `HOME` falso — `HOME=/tmp/fake ./install.sh` redireciona
  tudo (`~/.claude`, LaunchAgents) e é como as garantias de merge foram
  validadas. Cenários que importam: `settings.json` inexistente, com
  `statusLine` própria, com hook próprio no mesmo evento, com JSON inválido, e
  rodar duas vezes seguidas;
- app: `open` e olhar. `xattr -cr` já está no `build.sh` porque a pasta fica em
  Desktop sincronizado por iCloud e o `codesign` recusa bundle com xattr.

## Arquitetura

### Quatro fontes de uso, escolhidas por frescor

`Store` mantém **quatro snapshots separados** (`apiUsage`, `cacheUsage`,
`historyUsage`, `fileUsage`) e `publishUsage()` publica o de carimbo mais novo —
comparação por timestamp, nunca prioridade fixa, para o painel nunca andar para
trás. As fontes, em ordem de vivacidade: API (`/api/oauth/usage`),
`plan-usage-history.json` do app nativo do Claude, `cachedUsageUtilization` do
`~/.claude.json`, e `usage.json` da statusline.

O detalhe que quebra se alguém "simplificar": o vencedor manda no **número de
uso**, mas campos que o formato dele não carrega (`resets_at`, créditos extra)
são **herdados** do snapshot mais recente que os tenha. E a herança de
`extra_usage` é condicional (`source.carriesExtra`): se a fonte *podia* mandar o
campo e não mandou, o silêncio é a resposta — repescar o valor antigo faria o
painel mentir sobre crédito disponível.

Duas regras sobre `resets_at`, ambas custaram um sintoma visível:

- **Só se herda data no futuro.** Uma vencida marca o limite como `rolledOver` e
  apaga a porcentagem da menu bar — era o robô aparecendo sozinho com a máquina
  parada, escondendo um número fresco atrás do `usage.json` congelado.
- **`PlanHistory.inferReset` deduz a janela de 5h da própria série** (início da
  corrida de amostras com uso > 0, mais 5h; erro medido de −10 a +2 min). Data
  deduzida vem com `resetsAtIsEstimate`, aparece com `~`, nunca dispara
  `rolledOver`, e perde para qualquer data exata. Sem série que a sustente,
  devolve nil — o painel fica sem countdown, que é a verdade.

Rede: `maybeFetchAPI()` dispara ao **abrir o painel** (piso de 60s), não por
polling. O timer de 300s fica em silêncio enquanto o histórico do app nativo
estiver fresco (`passiveFresh`). Um 429 vira backoff de 10→60 min e o painel se
vira com disco.

### Custo e tokens — fonte independente

`CostScanner` + `Transcripts` leem `~/.claude/projects/**/*.jsonl` por
**deslocamento**: a primeira passada varre tudo, as seguintes leem só os bytes
novos (`cursors`), com corte de 35 dias. Sem isso seriam centenas de MB
reparseados a cada tick. Preço é tabela fixa (`Pricing`), com os quatro preços de
cache derivados do preço de entrada por multiplicador — modelo desconhecido
conta tokens e **não** inventa custo.

### Contrato entre os scripts e o app

`hook.py` e `statusline.py` escrevem `~/.claude/claude-bar/sessions/<id>.json`;
`Store.readSessions()` lê. Os dois lados dependem de detalhes que não são
óbvios de um lado só:

- `hook.py` grava `updated_at`, `statusline.py` grava `seen_at`; o app usa o
  **maior** dos dois. Sessão viva que renderiza statusline mas não bate em `Stop`
  há 6h seria descartada de outro jeito;
- `waiting_tool` casa `PermissionRequest` com o `PostToolUse` correspondente
  **por nome de ferramenta** (o `PermissionRequest` não carrega `tool_use_id`);
- `PermissionRequest` é o sinal primário de "travado", não `Notification` — o
  Claude Code só emite a notificação num `setInterval` de 6s e com gate de foco.

Escrita sempre atômica (tmp 0600 + `os.replace`), diretório 0700.

### Reveal: clique numa sessão foca a janela certa

`Reveal` sobe uma cadeia: processo do Claude Code daquela sessão (por
`--resume=<id>` ou por `cwd` via `lsof`) → processo pai (extension host, um por
janela) → porta TCP que ele escuta (`lsof`) → `~/.claude/ide/<porta>.lock` →
`workspaceFolders`. Só abre raiz de janela conhecida; sem raiz confirmada,
apenas ativa o app — pedir um caminho qualquer faria o editor abrir uma janela
nova. Do `.lock` lê **apenas** `workspaceFolders`, nunca o `authToken`.

### Threading

Main thread só publica. `io` (serial, utility) faz leitura de disco e o
subprocesso do `security`; `costQueue` é separada porque a primeira varredura de
transcripts seguraria a atualização das sessões por segundos. O `Timer` entra em
`RunLoop` no modo `.common` — em `.default` ele congela justamente enquanto o
popover está aberto.

## Invariantes

Estas não são preferências; cada uma custou um bug ou uma medição:

- **Nunca trocar `/usr/bin/security` por `SecItemCopyMatching`.** Parece mais
  limpo e traz de volta o diálogo "Permitir" a cada reboot: a ACL do item confia
  naquele binário, e é refeita a cada refresh de token.
- **Nunca renovar nem guardar o token.** O Claude Code é dono desse ciclo de
  vida; disputar isso invalida a sessão. Lê, usa, descarta.
- **Nunca escrever em `~/.claude`** a partir do app. A única escrita dele é
  `UserDefaults` (preferência de exibição).
- **Não baixar `apiInterval` (300s) nem remover o jitter/backoff.** O endpoint
  castiga polling com 429 de 30+ minutos, sem `Retry-After`.
- **Manter o `User-Agent` `claude-code/<versão>`** — sem ele a requisição cai num
  bucket de rate limit mais agressivo.
- **Hooks nunca decidem permissão**: nada de `permissionDecision`, nada de exit
  2, `sys.exit(0)` em qualquer situação. Hook que quebra não pode derrubar a
  sessão de ninguém.
- **`tool_input` nunca entra no label da sessão** — ele carrega comando e arquivo
  inteiros, e esse texto vai parar na menu bar.
- Toda fonte de disco degrada em silêncio: leitura que falhou (escrita pela
  metade do Claude Code, app nativo não instalado) **não apaga** número bom da
  tela.

## Convenções

- Comentários e nomes em português **sem acento**; strings de UI e README com
  acento normal.
- O comentário explica *por quê*, não *o quê*, e cita a medição quando existe
  ("medido: 75 ms", "2.6% de CPU"). É o padrão do arquivo inteiro — siga.
- Sem dependências. Python usa só a stdlib; Swift só Foundation/SwiftUI/AppKit.

## Publicação

`.gitignore` exclui `.claude/settings.local.json` (caminhos absolutos e histórico
da máquina), `.DS_Store` e `ClaudeBarLocal.app/` — **binário não vai para o
repositório de propósito**: quem clona compila. Antes de publicar, a varredura
está documentada na seção *Publicando um fork* do README.

`debug.jsonl` (modo diagnóstico) contém stdin cru dos hooks, incluindo conteúdo
de sessão. É o único arquivo sensível do projeto.
