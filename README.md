# claude-bar-local

Monitor de menu bar para o Claude Code, feito para rodar na sua máquina e ser
lido por inteiro numa sentada.

Sem auto-update, sem telemetria, sem dependência de terceiro. Uma única chamada
de rede, para um endpoint só, com a sua própria credencial — e **sem nunca pedir
autorização de Keychain**.

---

## Modelo de segurança

O motivo de existir é a origem dos dados. Apps de prateleira pegam uso chamando
a API da Claude com o seu `sessionKey` — credencial de conta inteira, guardada
num binário fechado que se atualiza sozinho. Aqui você compila o código e sabe
exatamente o que ele faz.

Quatro fontes, da mais viva para a mais teimosa:

| Componente | Lê | Escreve | Rede |
|---|---|---|---|
| `statusline.py` | stdin do Claude Code | `<config dir>/claude-bar/` | nenhuma |
| `hook.py` | stdin do Claude Code | `<config dir>/claude-bar/` | nenhuma |
| `ClaudeBarLocal.app` | Keychain (via `security`) + `<config dir>/.claude.json` + `<config dir>/claude-bar/` + `<config dir>/projects/**/*.jsonl` + `<config dir>/ide/*.lock` + `~/Library/Application Support/Claude/plan-usage-history.json` | `~/Library/Preferences/local.claudebar.plist` | 1 `GET`, a cada 5 min |

`<config dir>` é `~/.claude` quando você tem uma conta só. Com mais de uma, cada
conta tem o seu (`CLAUDE_CONFIG_DIR`) e nada atravessa de uma para a outra — ver
[Duas contas](#duas-contas-ou-mais).

Três subprocessos, os três somente-leitura: `/usr/bin/security` para o token (a
cada 5 min); `/bin/ps` e `/usr/sbin/lsof` para descobrir a janela do editor que
hospeda a sessão (só quando você clica numa linha).

Dos `*.lock` o app lê só `workspaceFolders` — a pasta que cada janela tem aberta.
Não abre a conexão que o lock anuncia e não toca no `authToken` que ele carrega.

A única escrita do app é a preferência de exibição (modo da menu bar, janela de
custo, altura da lista). Nada em `~/.claude` é tocado, e nenhuma dessas chaves
guarda dado de uso ou credencial:

```bash
defaults read local.claudebar
```

**1. API — a fonte viva.** É a única que atualiza sozinha. Ver abaixo por que ela
não pede autorização.

**2. `~/.claude.json` → `cachedUsageUtilization` — arranque instantâneo.** O
Claude Code guarda ali a última resposta crua de `/api/oauth/usage`, com
`fetchedAtMs`. Serve para o painel já nascer com número em vez de tracinho.

> **Não serve como fonte única.** Medido: em 30 minutos de trabalho pesado, esse
> valor foi reescrito **uma vez**. No binário do Claude Code só existe um
> caminho de escrita (`OOu`), chamado apenas pelo fetch que roda quando você abre
> o `/usage`, e ainda com throttle de 5 min (`WZg=300000`). Os números vivos que a
> sessão exibe vêm dos headers `anthropic-ratelimit-unified-*` de cada resposta e
> **ficam só em memória** — não vão para disco, nem para os transcripts.

```bash
python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude.json')))['cachedUsageUtilization']['fetchedAtMs'])"
```

**3. `plan-usage-history.json` — o app nativo trabalhando de graça.** O app do
Claude poleia o endpoint de uso sozinho a cada 300s e guarda 30 dias de amostras
em `~/Library/Application Support/Claude/`. Ler custa zero requisição e zero
credencial. Só anda com o app aberto — fechado, a última amostra envelhece e
perde para as outras na comparação por carimbo.

> **É esta fonte que enxerga o app nativo.** O limite de 5h/7d é da conta, não do
> Claude Code: o que você gasta conversando no app nativo ou na web entra no
> mesmo balde e aparece aqui. O painel de **custo** é outra história — ele conta
> tokens de transcript, e o chat do app nativo não deixa transcript em disco
> (conversa mora no servidor). Percentual vê tudo; custo em dólar vê só o CLI.

**4. `usage.json` — último recurso**, escrito pela statusline a partir de
`rate_limits.five_hour`/`seven_day`. A statusline **só roda no CLI**: a extensão
do VS Code não executa `statusLine`.

O painel mostra sempre a mais fresca das quatro, com origem e idade —
**comparação por carimbo, nunca prioridade fixa**, para o número nunca andar para
trás.

### Quem vence manda no número, não na agenda

O vencedor por frescor manda na **porcentagem**. Campos que o formato dele não
carrega — `resets_at`, créditos extra — são herdados do snapshot mais recente que
os tenha. Duas regras que parecem detalhe e não são:

- **Data de reset vencida não se herda.** O histórico do app nativo só traz
  porcentagem, e a única fonte com `resets_at` é a statusline — que congela
  quando você não usa o CLI. Herdar uma data do passado marca o limite como
  "janela reiniciada" e **apaga a porcentagem da menu bar**: robô sozinho na
  barra, com a máquina parada e um número perfeitamente bom escondido atrás de
  uma agenda morta. Só entra data no futuro.
- **`extra_usage` só é herdado de quem não podia mandá-lo.** Se a fonte
  *carregava* o campo e veio vazia, o silêncio é a resposta — repescar o valor
  antigo faria o painel mentir sobre crédito disponível.

### O `~` do countdown

Sem o CLI aberto ninguém tem `resets_at`, mas a série do app nativo tem o
suficiente para deduzi-lo. A janela de 5h não corre em grade fixa: ela ancora no
**primeiro uso** depois de zerar e morre 5h depois. Esse instante é visível — é o
começo da corrida atual de amostras com uso > 0.

Medido contra os 8 últimos resets de uma série real e contra o
`five_hour_resets_at` que a statusline havia gravado: **erro de −10 a +2 min,
mediana −7**. O sinal é sistemático e tem causa conhecida — com amostragem de
300s o primeiro uso cai antes da amostra que o revela, então a estimativa
adianta. Adiantar é o lado certo de errar: o countdown vence antes da janela,
nunca depois.

Por isso a data deduzida aparece com til (`~2h30`) e **nunca** marca uma janela
como reiniciada — errar dez minutos para menos apagaria da barra um número que
ainda vale. Se qualquer fonte tiver a data de verdade, ela ganha da estimativa. E
a dedução devolve *nada* em vez de chutar quando a série não a sustenta: uso
atual zerado, buraco maior que 30 min na série (app fechado, máquina dormindo),
amostra sem o campo, corrida que encosta na borda dos 30 dias, ou prazo que já
venceu sem o zero ter sido observado.

A janela de 7 dias fica de fora de propósito: ela quase nunca zera na série, e
sem uma borda observada a mesma conta viraria extrapolação a partir de nada.

**Quando nem a dedução sustenta, a API volta a ser consultada.** O poller fica em
silêncio enquanto o histórico do app nativo está fresco — ele já cobre o painel de
graça, e requisição a mais só aumenta a chance de 429. Só que o histórico carrega
*porcentagem*, não agenda: numa conta que vive só na extensão do VS Code (a
statusline nunca roda, e o `cachedUsageUtilization` dela envelhece), pode acontecer
de as quatro fontes terem número e nenhuma ter data. Medido em 12/09: histórico
fresco de 6 min, cache de 56h com data vencida, `usage.json` de 40 dias atrás, e a
dedução em `nil` por um vão de 115 min na série. A barra mostrava `100%` sem
relógio até alguém abrir o painel — abrir força o fetch, e o countdown aparecia
"sozinho".

A economia passou a exigir as duas coisas: histórico fresco **e** countdown já
publicado. Sem agenda, a requisição tem o que melhorar e volta ao ritmo normal de
300s com jitter — nunca abaixo dele, e o backoff de 429 continua acima de tudo.

### Por que não aparece o diálogo do Keychain

O app lê o token assim:

```bash
/usr/bin/security find-generic-password -s "Claude Code-credentials" -w
```

Isso **não** é um detalhe de estilo — é o que separa "funciona" de "pede
autorização para sempre". O Claude Code não usa a API `SecItem`: ele shella para a
CLI `security`. Então a ACL do item confia no binário `/usr/bin/security`, e só
nele. Um app próprio chamando `SecItemCopyMatching` é um requerente desconhecido:
o macOS abre o diálogo "Permitir" — e **"Sempre Permitir" não gruda**, porque a
ACL é refeita a cada refresh de token. Na prática: prompt novo a cada reboot.

Delegando para o mesmo binário que criou o item, quem o Keychain avalia é o
`/usr/bin/security`. Passa direto. Medido: 75 ms, zero diálogos, inclusive com o
app lançado por `launchd` no login.

**A única chamada de rede que existe:**

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <token do Keychain>
anthropic-beta: oauth-2025-04-20
User-Agent: claude-code/<versão>
```

Read-only, nada é enviado além do token. O app **nunca guarda o token** (lê, usa,
descarta) e **nunca o renova** — o Claude Code é dono desse ciclo de vida, e
disputar isso pode invalidar sua sessão. Token expirado significa cair para o
dado do disco e esperar.

> **O `User-Agent` se declara como o Claude Code.** Não é disfarce por esporte: o
> endpoint é o mesmo que o CLI chama, com a credencial da mesma sessão, e um UA
> estranho é o primeiro candidato a levar bloqueio. Ainda assim é uma escolha de
> política, não de segurança — se a Anthropic passar a exigir cliente
> identificado, ou tratar esse tráfego como não autorizado, este app é quem
> quebra. Some isso ao fato de o endpoint não ser documentado (ver *Limitações
> conhecidas*) antes de depender dele para qualquer coisa séria.

**O que este modelo não cobre:** o `security find-generic-password` funciona
porque a ACL do item confia naquele binário — qualquer processo rodando como
você já tinha esse acesso, com ou sem este app. Ou seja: isto protege contra
telemetria e contra terceiros na rede, **não** contra software malicioso já
rodando na sua conta. Nada rodando em user-space protegeria.

**Verificar você mesmo** (os dois primeiros comandos exigem o binário: rode
`./build.sh` antes):

```bash
# a rede que existe: api.anthropic.com e nada mais
strings ClaudeBarLocal.app/Contents/MacOS/ClaudeBarLocal | grep -iE 'https?://' | sort -u

# nenhuma API de Keychain linkada — o acesso é só via /usr/bin/security
nm -u ClaudeBarLocal.app/Contents/MacOS/ClaudeBarLocal | grep -i SecItem || echo "sem SecItem — ok"

# o que o app escreve, e onde
defaults read local.claudebar

# os scripts não tocam credencial
grep -n "credentials\|sessionKey\|sk-a[n]t" statusline.py hook.py || echo "sem credencial — ok"
```

---

## Duas contas (ou mais)

Se você usa uma conta na extensão do VS Code e outra no terminal — pessoal e da
empresa, tipicamente —, o painel mostra **as duas**, uma abaixo da outra, e a
menu bar mostra a da sessão que você está usando.

O que torna isso possível sem nenhuma adivinhação é como o próprio Claude Code
separa conta: por **config dir**. A padrão mora em `~/.claude` (com o
`~/.claude.json` ao lado); qualquer outra vive inteira dentro do
`CLAUDE_CONFIG_DIR` que você apontar — `.claude.json`, `projects/`, `ide/` e o
`claude-bar/` que os scripts escrevem. Então a conta de um dado **é o diretório
de onde ele veio**, nunca um palpite sobre qual sessão o produziu.

```bash
# a conta da empresa, no terminal
export CLAUDE_CONFIG_DIR=~/.claude-empresa

# instala em todas as contas que o app enxerga
./install.sh --all-accounts
```

A letra identifica quem é quem. Por padrão ela é posicional — **P** para a conta
padrão (`~/.claude`), **E** para as demais — e aparece na menu bar, no cabeçalho de
cada cartão do painel e na linha de cada sessão. Só quando há mais de uma conta:
com uma só, a barra fica exatamente como era, porque letra sem ambiguidade para
resolver é ruído ocupando largura.

**P/E é só o ponto de partida.** Clique no cabeçalho de qualquer cartão do painel
e escreva a letra (até 3 caracteres) e o nome que fizerem sentido para você —
`AC` / *Cliente Acme*, `T2` / *Time 2*, o que for. Vale para quem tem duas contas
de cliente, ou três, e não a divisão pessoal/empresa que o padrão supõe:

```
[E] voce@empresa.com   ✏️     ← clique no cabeçalho do cartão
[AC] Cliente Acme             ← e a barra passa a dizer AC
```

Campo vazio apaga a personalização e a conta volta ao padrão — não há botão
"restaurar" porque não é preciso. Os apelidos ficam em `UserDefaults`, indexados
pelo `accountUuid`: o custo acumulado continua indexado pelo **id**, não pela
letra, então renomear não deixa histórico órfão.

```
🤖 E 31%          ← a sessão ativa é a da empresa
🤖 P 54%          ← você voltou para a sessão do VS Code
```

Por padrão a barra segue a sessão ativa, mas dá para fixar uma conta ou mostrar
as duas empilhadas — ver [Qual conta a barra mostra](#qual-conta-a-barra-mostra).

Como cada fonte se comporta com duas contas:

| Fonte | Por conta? | Como |
|---|---|---|
| `cachedUsageUtilization` | sim | cada config dir tem o seu `.claude.json`, com `accountUuid` dentro |
| statusline (`usage.json`) | sim | cada conta escreve no `claude-bar/` do próprio config dir |
| `plan-usage-history.json` | sim | o arquivo é um só, mas cada amostra é carimbada com a `org` |
| API (`/api/oauth/usage`) | **não** | só a conta padrão — ver abaixo |

A API cobre apenas a conta padrão, e é uma limitação deliberada: o token sai do
item `Claude Code-credentials` do Keychain, que é o da instalação padrão. Um
config dir próprio guarda a credencial dele em **outro** item, cujo nome este
projeto ainda não confirmou — e atribuir a resposta da API à conta errada seria
pior do que a conta extra ficar sem essa fonte. Na prática ela não sente falta:
a conta extra costuma ser a do terminal, onde a statusline roda a cada prompt com
`rate_limits` vindo do próprio Claude Code, mais fresco que qualquer poleio.

O filtro por `org` no histórico do app nativo não é zelo: o app poleia a conta em
que **ele** está logado. Sem separar, a série de uma conta apareceria debaixo do
nome da outra — número errado com cara de fresco, que é o pior estado possível
deste painel. Sem org conhecida, a conta simplesmente não herda série nenhuma.

> **O que muda de risco.** O script é o mesmo e continua sem rede, sem credencial
> e sem decidir permissão. O que muda é o que passa por ele: com a segunda conta
> instalada, `debug.jsonl` (quando ligado) e o título da sessão na menu bar
> passam a carregar material daquela conta. Por isso o estado vive **dentro do
> config dir de cada uma** — inclusive a flag `DEBUG`, que é por conta: ligar o
> diagnóstico numa não captura conversa da outra.

### Como as contas são descobertas

`~/.claude` sempre, mais os irmãos `~/.claude-*` que tenham um `.claude.json`
dentro. É a convenção que se usa na prática, e o custo de errar é assimétrico: um
config dir fora do `$HOME` apenas não aparece no painel, enquanto adivinhar mais
que isso poria o número de uma conta debaixo do nome de outra. Uma cópia de
backup com `.claude.json` dentro entraria na lista — é por isso que cada cartão
mostra o e-mail da conta, e não só a letra.

---

## Instalação

Os arquivos ficam todos na raiz do repositório — não há subpastas.

> **Leia antes de rodar.** Este app lê a credencial da sua sessão do Claude Code
> e a instalação escreve hooks globais no seu `~/.claude/settings.json` — hooks
> valem para **todos** os seus projetos, não só para este. São ~2.700 linhas de
> Swift e dois scripts de ~200 linhas, escritos para serem lidos numa sentada:
> leia, ou pelo menos rode os comandos de *Verificar você mesmo* acima. A regra
> vale para qualquer software nessa posição, inclusive este.
>
> **Compile você mesmo.** O repositório não distribui binário de propósito (o
> `.app` está no `.gitignore`). O `build.sh` leva ~10 segundos e só precisa de
> `xcode-select --install`. Não aceite um `ClaudeBarLocal.app` pronto de
> ninguém — nem de mim.

### Caminho curto

```bash
./install.sh --dry-run     # mostra exatamente o que mudaria, sem tocar em nada
./install.sh               # aplica (só a conta padrão)
./install.sh --autostart   # idem, e ainda instala em /Applications + sobe no login

./install.sh --all-accounts              # todas as contas achadas
./install.sh --config-dir ~/.claude-empresa   # uma conta específica (pode repetir)
```

Sem `--config-dir` ou `--all-accounts`, só a conta padrão é tocada: instalar
sozinho hooks numa conta que o dono da máquina não pediu seria decidir por ele
onde eles rodam.

Faz os quatro passos manuais abaixo, e o terceiro — mesclar o `settings.json` —
com as garantias que o `cp` não tem:

- **confere os pré-requisitos antes de copiar qualquer coisa**, incluindo se o
  seu `settings.json` atual é JSON válido. Se não for, aborta sem instalar nada;
- **preserva o que é seu.** Hooks seus nos mesmos eventos continuam lá, inclusive
  quando estão no mesmo bloco que o nosso. Se você já tem uma `statusLine`, ela
  **não** é substituída — o script avisa e deixa a escolha com você;
- **backup datado** (`settings.json.bak.<timestamp>`) antes de escrever, e
  escrita atômica: um Ctrl-C no meio não deixa o arquivo pela metade;
- **idempotente.** Rodar de novo não duplica hook: se nada mudou, o arquivo nem
  é reescrito;
- `./install.sh --uninstall` desfaz tudo, removendo só o que é deste projeto.

Os passos manuais continuam abaixo — o script não faz nada que você não possa
fazer à mão, e ler os dois é a melhor forma de conferir isso.

### 1. Scripts

```bash
mkdir -p ~/.claude/claude-bar && chmod 700 ~/.claude/claude-bar
cp statusline.py hook.py ~/.claude/claude-bar/
chmod +x ~/.claude/claude-bar/*.py
```

Para outra conta, troque `~/.claude` pelo `CLAUDE_CONFIG_DIR` dela em todos os
caminhos deste passo e do próximo — inclusive dentro dos comandos do
`settings.json`, que apontam para os scripts do próprio config dir.

### 2. `~/.claude/settings.json`

**Faça backup antes** (`cp ~/.claude/settings.json{,.bak}`) e **mescle** os
blocos em vez de sobrescrever — hooks aqui valem para todos os seus projetos.

```json
{
  "statusLine": {
    "type": "command",
    "command": "python3 ~/.claude/claude-bar/statusline.py",
    "padding": 1,
    "refreshInterval": 10
  },
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "python3 ~/.claude/claude-bar/hook.py", "async": true } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "python3 ~/.claude/claude-bar/hook.py", "async": true } ] }
    ],
    "PermissionRequest": [
      { "hooks": [ { "type": "command", "command": "python3 ~/.claude/claude-bar/hook.py", "async": true } ] }
    ],
    "PermissionDenied": [
      { "hooks": [ { "type": "command", "command": "python3 ~/.claude/claude-bar/hook.py", "async": true } ] }
    ],
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "python3 ~/.claude/claude-bar/hook.py", "async": true } ] }
    ],
    "PostToolUseFailure": [
      { "hooks": [ { "type": "command", "command": "python3 ~/.claude/claude-bar/hook.py", "async": true } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "python3 ~/.claude/claude-bar/hook.py", "async": true } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "python3 ~/.claude/claude-bar/hook.py", "async": true } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "python3 ~/.claude/claude-bar/hook.py", "async": true } ] }
    ]
  }
}
```

`async: true` roda o hook em background sem travar o turno. `refreshInterval`
re-roda a statusline por timer além dos eventos, para o dado de fallback não
congelar com o terminal parado.

Confira com `/hooks` dentro do Claude Code — o menu lista o que está registrado
e de qual arquivo veio.

### 3. App

```bash
./build.sh && open ClaudeBarLocal.app
```

Não há prompt de permissão nenhum, nem no primeiro lançamento nem depois de
rebuildar: o acesso ao Keychain passa pelo `/usr/bin/security` (veja o modelo de
segurança), então a assinatura ad-hoc do app não entra na conta.

### 4. Auto-start (opcional)

```bash
cp -R ClaudeBarLocal.app /Applications/
cp local.claudebar.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.claudebar.plist
```

### 5. Propagar cada commit para o app que roda (opcional)

Com o auto-start ligado, quem sobe no login é `/Applications/ClaudeBarLocal.app`
— e `./build.sh` sozinho atualiza apenas o bundle da pasta do repositório. O
sintoma é silencioso e confunde: você edita, compila, e o ícone da menu bar
continua sendo o de antes, porque o `launchd` nunca ouviu falar do bundle novo.

`.githooks/post-commit` fecha essa distância. Ative uma vez por clone:

```bash
git config core.hooksPath .githooks
```

A cada commit ele olha o que mudou e faz só o necessário: `statusline.py` ou
`hook.py` mudaram, recopia para o `claude-bar/` de **cada conta que já os tenha**;
`ClaudeBarLocal.swift` mudou, roda o `build.sh`, substitui o bundle em
`/Applications` e reinicia o serviço. Commit que mexe só em documentação não
recompila nada.

Três detalhes que o hook não improvisa:

- **Não chama o `install.sh`, e não instala em conta nova.** Ele refaria o merge
  do `settings.json` e reinstalaria o LaunchAgent a cada commit; o hook toca
  apenas o que muda de um commit para o outro, e só em contas onde os scripts já
  estão. Registrar hooks globais numa conta que ninguém pediu, a partir de um
  commit, seria exatamente a surpresa que este projeto existe para não dar.
- **Reinicia com `launchctl kickstart -k`, não com `open`.** O processo precisa
  continuar sendo filho do agent — um `open` avulso ficaria órfão e o `launchd`
  o mataria no login seguinte.
- **Sai na hora durante rebase, merge e cherry-pick.** O `post-commit` dispara
  uma vez por commit replicado: sem essa guarda, um rebase de dez commits
  recompilaria dez vezes e piscaria a menu bar junto.

O hook nunca falha o commit — quando o `build.sh` quebra, ele avisa que
`/Applications` ficou na versão anterior e devolve `0`. Note que `core.hooksPath`
é configuração local: ela não vem no clone, e por isso o passo acima existe.

---

## Estados

| Estado | Quando | Menu bar |
|---|---|---|
| `waiting` | `PermissionRequest`; ou `Notification` com `notification_type` de `permission_prompt`, `agent_needs_input` ou `elicitation_dialog` | robô laranja, olhos piscando |
| `working` | `UserPromptSubmit`, `PermissionDenied`, ou `PostToolUse` que encerra uma espera | cor de texto, ciclo de quatro poses (balanço + olhos apertando) |
| `done` | `Stop` | verde |
| `idle` | `SessionStart`, ou `Notification` de `idle_prompt` | cor de texto, parado |

### Por que `PermissionRequest` e não só `Notification`

`Notification` sozinha não detecta aprovação — foi medido, não suposto. O Claude
Code emite a de `permission_prompt` assim:

```js
setInterval(() => { if (PeY(6000)) Jl({message, notificationType}) }, 6000)
// PeY(6000)  ==  Date.now() - lastInteractionTime >= 6000
// e o diálogo, ao montar, faz Ji(true) -> lastInteractionTime = now
```

Duas travas: a notificação só sai **6 s depois** do diálogo abrir, e **só se você
não encostar no teclado** nesse intervalo (qualquer tecla reempurra o relógio).
Aprovação respondida em menos de 6 s nunca gerava evento — e é a maioria delas.
A sessão bloqueada ficava invisível justamente no caso comum.

`PermissionRequest` dispara junto com o pedido, sem janela e sem gate de foco. E
sem falso positivo: ferramenta auto-aprovada não passa por ele (medido — 7
`PostToolUse` para 5 `PermissionRequest` numa sessão real).

O que **encerra** a espera é o `PostToolUse` (a aprovação saiu e a ferramenta
rodou) ou o `PermissionDenied` (você negou). Como o `PermissionRequest` não
carrega `tool_use_id`, o casamento é por `tool_name`: com chamadas em paralelo,
o `PostToolUse` da ferramenta auto-aprovada não apaga o `waiting` da que ainda
está parada no diálogo. `PostToolUse` só reescreve o arquivo se havia espera —
senão sairia um write por chamada de ferramenta só para regravar o mesmo estado.

Laranja é reservado para o que **bloqueia o trabalho**: permissão e pedido de
input. `idle_prompt` ("Claude está esperando você") vira cinza de propósito —
"terminou, é sua vez" já é o verde do `Stop`. Laranja em tudo vira ruído e você
para de olhar.

Com várias sessões abertas, a menu bar mostra a de maior prioridade: uma sessão
esperando você nunca fica escondida atrás de uma que está trabalhando.

O ícone é o mascote do Claude Code, desenhado em Core Graphics (`MenuIcon`) e
entregue ao `MenuBarExtra` como um `NSImage` de 18pt de altura — não como uma
`HStack` de SwiftUI. É isso que faz o item assentar no mesmo eixo vertical dos
vizinhos: com um `NSImage` pronto, quem centraliza é o AppKit, a mesma conta que
todo mundo na barra faz. A animação só liga quando há algo em andamento (10fps
em `working`, 2fps em `waiting`) e para sozinha depois.

A paleta do ícone é de propósito mais pobre que a do painel. O fundo ali é o
wallpaper, não uma superfície controlada: nenhum tom saturado sobrevive a um
papel de parede de cor parecida — azul sobre azul some. `labelColor` é a única
cor com contraste garantido, porque o próprio macOS a inverte conforme o que
está atrás da barra. Então a cor só é gasta nos dois estados que são *evento*:
`waiting` e `done`. `working` não precisa dela — o robô está se mexendo, e
movimento chama mais atenção que matiz.

A porcentagem ao lado herda a severidade do limite de 5h — cinza claro até 60%,
laranja a partir daí, vermelho acima de 85%, e esmaecida quando o dado está
velho.

### Por que a animação é de 2fps

Porque cada quadro por segundo do item custa **~1% de CPU contínuo**, e o
gargalo é a menu bar em si, não o SwiftUI — medido nesta máquina, com uma sessão
`working` aberta:

| Cadência | CPU (média de 60s) |
|---|---|
| sem animação | 0,5% |
| 2 fps (atual) | 2,5% |
| 5 fps | 5,8% |
| 10 fps | 10,9% |

Trocar `MenuBarExtra` por um `NSStatusItem` cru não compraria nada: o mesmo
desenho a 10fps por AppKit puro deu 7,6%. A 10fps seriam 10% de CPU pelas horas
em que o Claude trabalha, então a animação virou discreta: quatro poses num ciclo
de 2s, que a 2fps lê como intenção em vez de tremor. Dá para desligar de vez em
**Menu bar → Animar o robô**.

---

## Sessões

Cada linha mostra a **conversa**, não a pasta — o mesmo título que a aba do
editor mostra ("Melhorar alinhamento visual e adicionar mascote Claude"). A pasta
desce para a linha de baixo, junto com modelo, contexto e estado.

O título sai da linha `{"type":"ai-title","aiTitle":…}` do transcript, presente
em 262 dos 284 arquivos aqui. Duas coisas que a medição impôs:

- **É lido pela cauda, não pela cabeça.** O Claude Code regera o título conforme
  a conversa muda de assunto, e as duas versões divergem: num transcript aqui, o
  início dizia "Resolver **reprovação** de produtos no Google Merchant Center" e
  o fim, "Resolver **rejeição**…". O do fim é o que a aba mostra. Ler os últimos
  256KB custa o mesmo num arquivo de 200KB ou de 30MB.
- **O cache expira.** Congelar o primeiro título visto deixaria a lista mentindo
  depois que a conversa virasse outra coisa.

Sem `ai-title`, cai na primeira mensagem que você digitou; sem transcript (sessão
recém-criada), no nome da pasta.

O transcript é localizado por `<session-id>.jsonl` dentro de
`~/.claude/projects/`, e não reconstruindo o caminho a partir do `cwd`: a
codificação da pasta é destrutiva (`LP F1 Bolão` vira `-Users-…-LP-F1-Bol-o`) e
não dá para desfazer. O UUID é único, então procurar pelo nome é exato.

**Clicar na linha vai até a janela daquela sessão.** A cadeia inteira parte do
processo do Claude Code que atende a sessão, e não do caminho da pasta:

| Passo | Como | Resultado |
|---|---|---|
| sessão → processo | `--resume=<id>` na linha de comando; conversa nova não carrega o id, aí o critério é o `cwd` do processo | o processo `claude` daquela conversa |
| processo → janela | o pai dele é o **extension host**, e há um por janela do editor | pid da janela |
| janela → pasta | a porta TCP que esse host escuta nomeia o `~/.claude/ide/<porta>.lock`, que traz os `workspaceFolders` | a raiz que a janela tem aberta |
| pasta → foco | abrir essa raiz **com aquele editor** | o editor foca a janela existente |

O editor sai do processo **daquela** sessão: sobe-se do extension host dela até o
bundle `.app` que o contém, sem tabela de nomes — VS Code, Cursor, Windsurf ou
qualquer fork funcionam sem o app precisar conhecê-los. Sair do processo certo
importa com dois editores abertos ao mesmo tempo: pedir a raiz no app errado é
justamente o que abre janela nova.

**Escala com o número de janelas** porque nada aqui compara janelas entre si —
cada uma tem seu extension host, sua porta e seu lock, e a busca é uma consulta
direta por sessão. Medido com três janelas abertas (`ClaudeStatus`, `OCDA` e
`~/.claude/claude-bar`): cada sessão resolve para a sua. E com
`CGWindowListCopyWindowInfo`: pedir cada raiz alterna qual fica na frente, de
forma determinística, e a contagem de janelas nunca muda — ele foca, não cria.

O passo que faltava era o do meio. Antes o app casava o `cwd` da sessão com as
raízes dos locks por prefixo, e **caía no `cwd` cru quando nada casava** — foi o
que abriu janela aleatória: sessão rodando em `~/.claude/claude-bar/sessions`
(diretório adicional, dentro de workspace nenhum) virava pedido de uma pasta
solta, e o editor materializa uma janela nova para isso. Indo pelo processo, o
`cwd` não precisa ser raiz de nada: a janela é a que hospeda a sessão, por
construção.

O casamento por caminho sobrou como rede de segurança, para quando o extension
host não está escutando porta nenhuma — a janela recarrega a extensão e o lock
antigo envelhece antes de o novo subir. Aí vale a raiz que **contém** o `cwd`,
entre as raízes de todas as janelas, com a mais específica ganhando o desempate
(`/a/b` ganha de `/a`, e `/a/b` nunca casa com `/a/bc`). Sem nenhuma que contenha,
a resposta é nil — a primeira raiz da lista seria a janela de outro projeto.

Duas limitações honestas:

- **A granularidade é a janela, não a aba.** Várias conversas na mesma janela não
  se separam — não há como escolher a aba de fora. Duas janelas do *mesmo*
  projeto também não: as duas reportam a mesma raiz, então quem escolhe é o
  editor. Fazer melhor exigiria a API de Acessibilidade, cuja permissão é
  amarrada à assinatura — sendo o app ad-hoc, ela cairia a cada build que mude o
  binário (veja abaixo).
- **Sem raiz confirmada, o clique só ativa o editor.** É o caso da sessão já
  encerrada (não há mais processo para inspecionar) cujo `cwd` não está dentro de
  nenhuma janela aberta. Cai na última janela usada — de propósito: chutar um
  caminho é o que abre janela errada. Sessão de terminal, sem editor nenhum, cai
  no Finder.

Essa é a única funcionalidade que roda subprocesso além do `security`: um
`/bin/ps` e até dois `/usr/sbin/lsof`, somente-leitura, apenas no clique. Custam
~200 ms, então rodam fora da main thread — só o resultado volta para ela.

### Por que Acessibilidade não é opção aqui

O TCC não guarda "permiti para este app". Ele guarda a permissão junto de uma
**exigência de assinatura** e revalida o binário a cada uso. O que o app assinado
ad-hoc oferece como exigência é isto:

```bash
codesign -d -r- ClaudeBarLocal.app
# designated => cdhash H"a57332680c29a5702f62cdf688ad96b56a2991ea"
```

O hash do código, e nada mais — sem Team ID, sem cadeia de certificado para
ancorar. Compare com um app assinado de verdade, cuja identidade é o certificado
e por isso sobrevive a updates:

```bash
codesign -d -r- "/Applications/Visual Studio Code.app"
# designated => identifier "com.microsoft.VSCode" and anchor apple generic
#               and ... certificate leaf[subject.OU] = UBF8T346G9
```

Medido: `./build.sh` sem mudar nada devolve o mesmo `cdhash` — a build é
reprodutível, então rebuildar por rebuildar não custa nada. Mas trocar **uma
linha de comentário** já troca o hash inteiro (`55a90eb7…` → `afd39bd7…`), e a
permissão concedida ao hash anterior deixa de valer para o novo binário. Ou seja:
toda vez que você mexer no código — que é o motivo de o projeto ser compilável
por você — a permissão precisaria ser reconcedida na mão.

É a mesma raiz do problema do Keychain, e o mesmo motivo de o app não linkar
`SecItem`: sem identidade estável, todo mecanismo que confia em assinatura te
trata como um app novo a cada build. No Keychain dá para delegar ao
`/usr/bin/security`, que tem identidade estável; para a API de Acessibilidade não
existe delegação equivalente.

---

## Modos da menu bar

O item mostra sempre o robô; o que vai escrito ao lado é escolha sua, em
**Menu bar** no rodapé do painel:

| Modo | Mostra |
|---|---|
| Só o robô | nada além do ícone |
| Uso da sessão (5h) (padrão) | `54%` |
| Tempo até reiniciar | `2h14` — contagem regressiva da janela de 5h |
| Uso + tempo até reiniciar | `54% \| 2h14` — os dois acima lado a lado |
| Custo de hoje | `$32.63` |

Com a conta em **0%** o relógio vira `ao usar` (`0% | ao usar`). Não é rodeio: a
janela de 5h ancora no seu **primeiro uso** e morre 5h depois, então antes dele
não existe hora nenhuma para contar — nem a API tem esse campo. O que existia
antes era pior: o campo sumia, e `0%` sozinho na barra é indistinguível de um bug.
No cartão a mesma situação aparece como *janela começa no próximo uso*.

No modo combinado o separador só aparece quando os dois lados existem: com o
limite virado sobra o relógio, sem `resets_at` sobra a porcentagem. É o modo mais
largo da lista — vale a pena se você tem espaço na barra, incomoda se a sua já
está cheia.

O modo é uma escolha; **qual conta** ele descreve é outra, e as duas se combinam
livremente.

### Qual conta a barra mostra

Com mais de uma conta, a letra dela entra na frente (`E 31%`, `P 54% | 2h14`) e
um segundo menu aparece no rodapé do painel, em **Menu bar → Conta na barra**:

| Escolha | Barra |
|---|---|
| Sessão ativa (padrão) | a conta da sessão que o robô está descrevendo |
| Ambas (duas linhas) | as duas empilhadas, em corpo menor |
| `P — seu@email` / `E — …` | sempre aquela conta, mude você de sessão ou não |

*Sessão ativa* segue a sessão que manda no ícone — não a mais recente nem a que
está pior. Ícone e número falando de sessões diferentes deixaria a barra dizendo
que uma conta está travada enquanto mostra a porcentagem da outra.

*Ambas* empilha as duas linhas dentro dos mesmos 18pt de altura do item, em 8,5pt
semibold: 12pt não cabe duas vezes, e o peso compensa o corpo menor. Cada linha
tem o **seu** destaque — marcar as duas pela pior esconderia justamente qual delas
está doendo.

```
🤖 P 100%          ← vermelho: a pessoal estourou a janela
   E 31%
```

Com uma conta só, nada disso aparece: sem ambiguidade para resolver, letra e
submenu seriam ruído. No modo *Custo de hoje* o número também passa a ser por
conta quando há mais de uma — a letra na frente promete que aquele valor é daquele
login, e um total somado ali desmentiria a promessa.

Os dígitos são monoespaçados de propósito: sem isso o item mudaria de largura a
cada ponto percentual e empurraria os vizinhos da barra.

Sessão esperando decisão não troca o que está escrito: quem avisa é o robô, que
fica laranja e pisca. O texto é o único lugar onde a porcentagem cabe, e ela não
pode sumir justamente na hora em que está alta.

### Como o limite alto aparece

Acima de 85% a barra realça o número, e o **como** é escolha sua, no mesmo menu:

| Destaque | O que faz |
|---|---|
| Etiqueta *(padrão)* | o número vai dentro de uma pílula vermelha sólida, em branco |
| Cor no número | o número fica vermelho, sem fundo |
| Nenhum | o número não muda; quem avisa é só o robô |

A etiqueta é o padrão por um motivo mecânico: **o fundo da menu bar é o seu
wallpaper**, não uma superfície controlada. Texto vermelho depende de sorte com o
que estiver atrás — sobre um fundo escuro azulado ele tem luminância vizinha à do
fundo e lê como borrão justamente no estado que mais precisa ser lido, e em 8,5pt
(as duas linhas do modo *Ambas*) piora. A etiqueta leva o próprio fundo: o
contraste que importa passa a ser branco-sobre-vermelho, que não depende de nada.

*Cor no número* é o comportamento anterior, preservado para quem prefere a barra
sem blocos sólidos — ele usa um coral no modo escuro e um carmim no claro, mais
legíveis que o `systemRed`. Aviso de 60% a 85% continua em laranja de texto nos
dois modos: laranja tem luminância alta e não sofre do mesmo problema, e duas
cores sólidas na barra ao mesmo tempo competiriam entre si.

Dado velho nunca ganha destaque, em modo nenhum: alarmar sobre um número
congelado é alarmar sobre um estado que talvez nem exista mais.

---

## Custo e tokens

Quarta fonte de dados, independente das outras três e a única que não depende de
nada além do disco: os transcripts em `<config dir>/projects/**/*.jsonl`. Cada
mensagem do assistente carrega o `usage` completo (entrada, saída, escrita e
leitura de cache, com o TTL separado) e o `cwd` do projeto.

Com duas contas, o `projects/` de cada uma é varrido e o painel ganha um
detalhamento **Por conta**, acima de *Por projeto* — que é a primeira pergunta
quando o mesmo projeto aparece nas duas.

**Sem rede e sem credencial.** O preço é tabela fixa no código, com os quatro
preços de cache derivados do preço de entrada por multiplicadores da Anthropic —
escrita 1,25× (TTL de 5min) e 2× (1h), leitura 0,1×. Só a base fica escrita, ou
uma tabela de cinco colunas por modelo envelheceria sem ninguém notar qual célula
ficou velha.

O painel mostra hoje / 7 dias / 30 dias, com custo, tokens, um gráfico de barras
por dia e o detalhamento por projeto e por modelo. Modelo fora da tabela de
preços conta os tokens e **avisa** que o custo está abaixo do real, em vez de
mostrar um total que finge estar completo.

**Como a leitura é feita.** Os arquivos só crescem no fim, então cada um tem um
deslocamento guardado: a primeira varredura passa pelos 300MB (~5s, em fila
própria, com o painel dizendo "lendo os transcripts…"), e as seguintes leem só os
bytes novos. Três detalhes que a medição obrigou:

- **`read(2)`, não `FileHandle.read(upToCount:)`.** Nos mesmos 317MB: FileHandle
  chegou a 329MB de pico e 1,81s; o POSIX fez 8,7MB e 0,11s.
- **`autoreleasepool` por bloco.** `JSONSerialization` devolve objetos
  autoreleased que, sem a piscina, ficam vivos até o fim da varredura: 110MB de
  pico contra 39MB.
- **A última linha incompleta nunca é consumida.** Se o arquivo não termina em
  `\n`, o Claude Code está escrevendo agora — o deslocamento não avança sobre ela,
  ou o registro se perderia.

Mensagens são deduplicadas por `message.id` + `requestId` (uma sessão retomada
repete linhas entre arquivos), e `<synthetic>` — mensagem fabricada pelo próprio
CLI — é ignorada.

**Conferir você mesmo:** os números foram validados contra uma implementação
independente em Python sobre os mesmos arquivos, batendo até a quarta casa
decimal nas três janelas. Se quiser repetir, o cálculo é
`(entrada + escrita5m×1,25 + escrita1h×2 + leitura×0,1) × preço_entrada + saída ×
preço_saída`, dividido por 1 milhão.

O painel sempre rotula **origem e idade** do número (`API · agora`,
`cache do Claude Code · há 14min`) e esmaece depois de 15 minutos. Quando a
origem é o cache, a idade vem do `fetchedAtMs` — quando o Claude Code buscou o
número, não quando o arquivo foi tocado. Um número velho nunca deve se passar por
vivo.

---

## Modo diagnóstico

Para inspecionar o que o Claude Code realmente manda nos hooks e na statusline
da **sua** versão, em vez de confiar na documentação:

```bash
touch ~/.claude/claude-bar/DEBUG
# use o Claude Code normalmente por uns minutos
python3 -m json.tool < ~/.claude/claude-bar/debug.jsonl   # uma linha por evento
rm ~/.claude/claude-bar/DEBUG ~/.claude/claude-bar/debug.jsonl
```

A flag é **por conta**: ela vale para o config dir em que está. Ligar o
diagnóstico na conta pessoal não faz o stdin cru da conta da empresa parar no
mesmo arquivo — para capturar a outra, `touch` no `claude-bar/` dela.

Útil para descobrir se `notification_type` existe na sua versão e quais valores
ele assume.

> **`debug.jsonl` guarda o stdin cru dos hooks — o que inclui conteúdo das suas
> sessões** (prompt submetido, nome de ferramenta, caminhos, mensagem da
> notificação). Nasce `0600` dentro de um diretório `0700`, mas é o único arquivo
> deste projeto com conteúdo sensível. Ligue quando precisar, **apague quando
> terminar**, e nunca deixe entrar num commit ou num anexo de bug report.

---

## Bônus: notificação nativa sem app nenhum

Se você só quer o aviso de "Claude precisa de aprovação", o Claude Code faz
isso sozinho — um hook `Notification` que devolve `terminalSequence` dispara
notificação de desktop pelo terminal, sem instalar nada:

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [ {
          "type": "command",
          "command": "python3 -c \"import json,sys;d=json.load(sys.stdin);m=d.get('message','Precisa de você');print(json.dumps({'terminalSequence':'\\033]777;notify;Claude Code;'+m+'\\007'}))\""
        } ]
      }
    ]
  }
}
```

**Requer Claude Code 2.1.141+** (`terminalSequence` não existe antes disso) e um
terminal compatível: Ghostty, WezTerm, iTerm2 ou Kitty. Terminal.app não suporta.

---

## Desinstalar

```bash
./install.sh --uninstall
```

Remove os hooks e a `statusLine` **deste projeto** do `settings.json` (com backup,
e sem encostar no que for seu), descarrega o LaunchAgent, apaga o app de
`/Applications` e o `~/.claude/claude-bar`. Ele respeita as mesmas opções de
conta da instalação: sem elas, desinstala só da conta padrão — use
`--all-accounts` para tirar de todas. À mão, se preferir:

```bash
launchctl bootout gui/$(id -u)/local.claudebar 2>/dev/null
rm -f ~/Library/LaunchAgents/local.claudebar.plist
rm -rf /Applications/ClaudeBarLocal.app ~/.claude/claude-bar
# e remova os blocos statusLine/hooks do ~/.claude/settings.json
```

Kill switch temporário: `"disableAllHooks": true` no settings.json desliga todos
os hooks sem apagar nada (a statusline é configuração separada e continua).

---

## Limitações conhecidas

- **O endpoint de uso não é documentado.** Foi descoberto por engenharia reversa
  do CLI, e a Anthropic fechou como "not planned" a issue sobre ele devolver 429
  agressivo. Pode mudar ou sair do ar sem aviso. É por isso que as fontes de disco
  continuam como fallback: se a API sumir, o app degrada em vez de morrer.
- **O endpoint castiga polling.** Há relato de 429 em intervalos de 30s a 300s
  persistindo por mais de 30 minutos, sem `Retry-After`. O app usa 300s com
  jitter e faz backoff de 10 até 60 minutos ao tomar 429. Não diminua esse
  intervalo.
- **`cachedUsageUtilization` não é formato documentado** nem confiável como fonte
  única — é estado interno do Claude Code e só é reescrito quando você abre o
  `/usage`. Serve para arrancar rápido, não para manter o número vivo.
- `rate_limits` na statusline só aparece para assinantes Claude.ai (Pro/Max), só
  depois da primeira resposta da sessão, e **só no CLI** — a extensão do VS Code
  não executa `statusLine`.
- **Não troque o `/usr/bin/security` por `SecItemCopyMatching`.** Parece mais
  limpo e é a armadilha: volta o diálogo "Permitir" a cada reboot, porque a ACL
  do item é refeita a cada refresh de token e não guarda a sua resposta.
- Sessões cujo terminal foi fechado à força não disparam `SessionEnd`; o app
  ignora arquivos parados há mais de 6h.
- **A API cobre só a conta padrão** (ver [Duas contas](#duas-contas-ou-mais)): o
  nome do item de Keychain de um `CLAUDE_CONFIG_DIR` próprio não está confirmado,
  e chutar poria o número de uma conta debaixo do nome de outra. As contas extras
  vivem das outras três fontes.
- **Contas são descobertas por convenção** — `~/.claude` e os irmãos `~/.claude-*`
  com `.claude.json` dentro. Um config dir fora do `$HOME` não aparece no painel;
  uma cópia de backup com `.claude.json` dentro aparece (com o e-mail dela, que é
  como você percebe).
- **Sem Xcode, o SDK mais novo pode não compilar.** O SwiftUI do SDK 27 declara
  `@State` como macro, e o plugin que expande macro (`libSwiftUIMacros.dylib`) só
  vem com o Xcode completo — nos Command Line Tools sozinhos o build morre em
  `plugin for module 'SwiftUIMacros' not found`, mesmo em código que compilava na
  véspera. O `build.sh` detecta isso com um probe de 0,35s e cai para o SDK mais
  novo que ainda funcione; se nenhum funcionar, ele diz para instalar o Xcode em
  vez de despejar erro de compilação.
- O app é assinado ad-hoc: roda porque você mesmo compilou, mas não é notarizado
  e não deve ser distribuído para outras máquinas assim.

---

## Publicando um fork

O `.gitignore` exclui quatro coisas, e nenhuma é por arrumação:

| Ignorado | Por quê |
|---|---|
| `.claude/settings.local.json` | Regras de permissão com caminhos absolutos, nomes dos seus projetos e o histórico do que você investigou. Não é segredo — é impressão digital da sua máquina. |
| `.DS_Store` | Vaza nomes de arquivos que já estiveram na pasta. |
| `ClaudeBarLocal.app/` | Binário ad-hoc. Publicá-lo é pedir que confiem num blob que ninguém pode verificar — exatamente o padrão que este projeto existe para evitar. |
| `*.o`, `*.dSYM/` | Sobras de compilação. |

O que **não** está ignorado (código, README, `build.sh`, `.plist`) foi conferido:
não há token, e-mail, caminho pessoal nem nome de projeto seu em nenhum deles.
Antes de publicar, confirme que continua assim:

```bash
# As classes de um caractere (sk-a[n]t) existem para o comando não casar consigo
# mesmo ao varrer este README.
git ls-files -z | xargs -0 grep -nIE 'sk-a[n]t|gh[p]_|Bearer [A-Za-z0-9]|/Users/[a-z]' \
  || echo "limpo"
```

E confirme que o diagnóstico está desligado — `debug.jsonl` vive fora do
repositório, mas não custa:

```bash
ls ~/.claude/claude-bar/DEBUG 2>/dev/null && echo "DEBUG LIGADO — desligue"
```

---

## Licença

MIT — veja [LICENSE](LICENSE).
